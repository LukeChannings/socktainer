import ContainerResource
import ContainerRuntimeClient
import Foundation

/// Materialises the on-disk *bundle* (including `rootfs.ext4`) for a
/// created-but-not-started container so its root filesystem can be edited
/// offline — e.g. `PUT /containers/{id}/archive` (`docker cp`) issued before
/// `docker start`.
///
/// ## Why this is needed
///
/// Apple Container writes only `runtime-configuration.json` at *create* time.
/// The `rootfs.ext4` block device is materialised lazily at *bootstrap* (start),
/// by `RuntimeService`:
///
/// ```swift
/// if !self.bundleExists(at: self.root) { try self.createBundle() }
/// ```
///
/// `bundleExists` is true **iff `config.json` exists and parses**, and
/// `createBundle()` clones the image's create-snapshot into `rootfs.ext4` via
/// APFS `clonefile`. Crucially, `Bundle.create` uses `FileManager.copyItem`,
/// which throws if `rootfs.ext4` already exists — so a *partial*
/// (rootfs-only) materialisation would break the subsequent start.
///
/// This provisioner therefore writes the **complete** bundle by calling Apple's
/// own `ContainerResource.Bundle.create` with the fields recorded in
/// `runtime-configuration.json` — byte-for-byte what bootstrap would produce.
/// Because the resulting `config.json` makes `bundleExists` return true, the
/// later `start` skips regeneration and boots the exact `rootfs.ext4` we
/// materialised (with any offline edits intact). This was verified empirically:
/// a self-materialised bundle boots and is reused verbatim.
///
/// Provisioning is idempotent (a no-op when `rootfs.ext4` already exists, which
/// covers started, stopped and Testcontainers `reuse=true` containers) and
/// serialised per container id so concurrent `PUT`s never race two clones.
actor ContainerRootfsProvisioner {
    private let appSupportPath: URL

    /// In-flight materialisations keyed by container id. A second caller for the
    /// same id awaits the first task rather than starting a competing clone
    /// (which would fail with `copyItem`'s file-exists error).
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(appSupportPath: URL) {
        self.appSupportPath = appSupportPath
    }

    private func containerDirectory(_ id: String) -> URL {
        appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(id)
    }

    /// Path to a container's `rootfs.ext4`, whether or not it exists yet.
    nonisolated func rootfsPath(forDirectory directory: URL) -> URL {
        directory.appendingPathComponent("rootfs.ext4")
    }

    /// Ensure a materialised bundle exists for `containerId`, returning the path
    /// to its `rootfs.ext4`. No-op (fast path) when the rootfs already exists.
    @discardableResult
    func ensureRootfs(containerId: String) async throws -> URL {
        let directory = containerDirectory(containerId)
        let rootfs = rootfsPath(forDirectory: directory)

        if FileManager.default.fileExists(atPath: rootfs.path) {
            return rootfs
        }

        if let existing = inFlight[containerId] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try Self.materialiseBundle(containerDirectory: directory, rootfs: rootfs)
            return rootfs
        }
        inFlight[containerId] = task
        defer { inFlight[containerId] = nil }
        return try await task.value
    }

    /// Replicate `RuntimeService.createBundle()`: read the stored runtime
    /// configuration and produce the full bundle via Apple's `Bundle.create`.
    private static func materialiseBundle(containerDirectory directory: URL, rootfs: URL) throws {
        // Idempotency guard against a materialisation that completed between the
        // actor-isolated check and this task body executing.
        if FileManager.default.fileExists(atPath: rootfs.path) {
            return
        }

        let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: directory)

        // Materialise into `directory` (where both this daemon's PUT path and
        // Apple's bootstrap look), rather than the `path` embedded in the config
        // — the two are identical in practice, but this removes the assumption.
        _ = try ContainerResource.Bundle.create(
            path: directory,
            initialFilesystem: runtimeConfig.initialFilesystem,
            kernel: runtimeConfig.kernel,
            containerConfiguration: runtimeConfig.containerConfiguration,
            containerRootFilesystem: runtimeConfig.containerRootFilesystem,
            options: runtimeConfig.options
        )
    }
}
