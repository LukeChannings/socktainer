import ContainerAPIClient
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// Tests for `ContainerRootfsProvisioner`, which materialises the on-disk
/// bundle (including `rootfs.ext4`) for a created-but-not-started container by
/// replaying Apple's own `Bundle.create` against the stored
/// `runtime-configuration.json`.
@Suite("ContainerRootfsProvisioner")
struct ContainerRootfsProvisionerTests {

    @Test("materialises rootfs.ext4 (and config.json) for a created container by cloning the recorded snapshot")
    func materialisesBundle() async throws {
        let fixture = ProvisionerFixture()
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer(id: "created-1", sentinelPath: "/socktainer-sentinel")

        let provisioner = ContainerRootfsProvisioner(appSupportPath: fixture.appSupport)
        let rootfs = try await provisioner.ensureRootfs(containerId: "created-1")

        #expect(FileManager.default.fileExists(atPath: rootfs.path), "rootfs.ext4 must be materialised")
        let dir = fixture.containerDir("created-1")
        // config.json is what makes Apple's bootstrap skip regeneration and reuse
        // this bundle, so it must be present after provisioning.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kernel.bin").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("initfs.ext4").path))

        // The materialised rootfs is a clonefile of the recorded snapshot, so it
        // must carry the snapshot's contents.
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        #expect(reader.exists(FilePath("/socktainer-sentinel")), "clone must preserve the snapshot's files")
    }

    @Test("is a no-op when rootfs.ext4 already exists")
    func idempotentWhenRootfsExists() async throws {
        let fixture = ProvisionerFixture()
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer(id: "created-2", sentinelPath: "/socktainer-sentinel")

        let provisioner = ContainerRootfsProvisioner(appSupportPath: fixture.appSupport)
        _ = try await provisioner.ensureRootfs(containerId: "created-2")
        // A second call must not throw (e.g. via copyItem onto an existing file).
        let again = try await provisioner.ensureRootfs(containerId: "created-2")
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    @Test("concurrent provisioning of one container serialises to a single materialisation")
    func concurrentProvisioningIsSerialised() async throws {
        let fixture = ProvisionerFixture()
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer(id: "created-3", sentinelPath: "/socktainer-sentinel")

        let provisioner = ContainerRootfsProvisioner(appSupportPath: fixture.appSupport)
        // If provisioning were not serialised per id, a second concurrent
        // Bundle.create would fail cloning onto the just-created rootfs.ext4
        // (copyItem throws when the destination already exists).
        try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask { try await provisioner.ensureRootfs(containerId: "created-3") }
            }
            var results: [URL] = []
            for try await url in group {
                results.append(url)
            }
            #expect(results.count == 8)
            #expect(Set(results.map(\.path)).count == 1, "all callers must resolve to the same rootfs path")
        }
    }
}

/// Builds a temporary `com.apple.container` app-support tree containing a
/// created-but-not-started container: a valid ext4 snapshot, dummy init/kernel
/// blobs, and a `runtime-configuration.json` pointing at them — exactly the
/// state Apple leaves after `container create` (no `rootfs.ext4` yet).
private struct ProvisionerFixture {
    let appSupport: URL

    init() {
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisioner-test-\(UUID().uuidString)")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    func containerDir(_ id: String) -> URL {
        appSupport.appendingPathComponent("containers").appendingPathComponent(id)
    }

    func writeCreatedContainer(id: String, sentinelPath: String) throws {
        let dir = containerDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A real ext4 snapshot carrying a sentinel so the clone can be verified.
        let assets = appSupport.appendingPathComponent("assets-\(id)")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let snapshot = assets.appendingPathComponent("rootfs-snapshot.ext4")
        let formatter = try EXT4.Formatter(FilePath(snapshot.path))
        let stream = InputStream(data: Data("sentinel\n".utf8))
        stream.open()
        try formatter.create(path: FilePath(sentinelPath), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
        try formatter.close()

        // Dummy init/kernel blobs — Bundle.create only copies these verbatim.
        let initBlob = assets.appendingPathComponent("initfs-snapshot.ext4")
        try Data("init-blob".utf8).write(to: initBlob)
        let kernelBlob = assets.appendingPathComponent("vmlinux")
        try Data("kernel-blob".utf8).write(to: kernelBlob)

        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        let config = ContainerConfiguration(id: id, image: image, process: proc)

        let runtimeConfig = RuntimeConfiguration(
            path: dir,
            initialFilesystem: .block(format: "ext4", source: initBlob.path, destination: "/", options: ["ro"]),
            kernel: Kernel(path: URL(fileURLWithPath: kernelBlob.path), platform: .linuxArm),
            containerConfiguration: config,
            containerRootFilesystem: .block(format: "ext4", source: snapshot.path, destination: "/", options: [])
        )
        try runtimeConfig.writeRuntimeConfiguration()
    }
}
