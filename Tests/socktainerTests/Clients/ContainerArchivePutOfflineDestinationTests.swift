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

/// Regression tests for FOLLOW-UP-2: `PUT /containers/{id}/archive` on a
/// non-running container must return 404 when the destination directory does
/// not exist inside the rootfs, and 400 when it exists but is not a directory
/// — matching Docker Engine API v1.51 and the running-container path. Before
/// the fix, the offline `putArchiveFallback` unpacked entries at
/// `<destination>/<entry>` and the ext4 formatter happily created any missing
/// intermediate directories, silently returning 200.
@Suite("ClientArchiveService.putArchive destination validation (offline)")
struct ContainerArchivePutOfflineDestinationTests {

    @Test("PUT to a non-existent destination directory raises pathNotFound (route: 404)")
    func putToMissingDestination() async throws {
        let fixture = OfflineDestinationFixture(id: "missing-dest")
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer()

        let container = try makeContainerSnapshot(
            nativeId: "missing-dest", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)
        let tar = try fixture.makeTar(fileName: "z", contents: "y\n")
        defer { try? FileManager.default.removeItem(at: tar) }

        do {
            try await fixture.service.putArchive(
                container: container,
                path: "/completely/absent/dir",
                tarPath: tar,
                noOverwriteDirNonDir: false)
            Issue.record("expected pathNotFound; got success")
        } catch let error as ClientArchiveError {
            guard case .pathNotFound = error else {
                Issue.record("expected pathNotFound; got \(error)")
                return
            }
        }

        // The destination is validated against the image snapshot before
        // anything is written: a rejected PUT on a never-started container
        // must neither provision a rootfs nor auto-create the missing directory.
        #expect(
            !FileManager.default.fileExists(atPath: fixture.rootfs.path),
            "a rejected PUT must not materialise the container's rootfs")
    }

    @Test("PUT to `/` still returns success (regression guard against over-tightening)")
    func putToRootStillWorks() async throws {
        let fixture = OfflineDestinationFixture(id: "root-dest")
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer()

        let container = try makeContainerSnapshot(
            nativeId: "root-dest", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)
        let tar = try fixture.makeTar(fileName: "injected.txt", contents: "ok\n")
        defer { try? FileManager.default.removeItem(at: tar) }

        try await fixture.service.putArchive(
            container: container, path: "/", tarPath: tar, noOverwriteDirNonDir: false)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.rootfs.path))
        #expect(reader.exists(FilePath("/injected.txt")))
    }

    @Test("PUT to a symlink pointing at a regular file raises invalidPath (route: 400)")
    func putToSymlinkToNonDirectory() async throws {
        let fixture = OfflineDestinationFixture(id: "symlink-dest")
        defer { fixture.cleanUp() }
        // Base rootfs has `/etc/hostname` (a regular file) and `/link` → `etc/hostname`.
        try fixture.writeCreatedContainer(extraSymlink: (path: "/link", target: "etc/hostname"))

        let container = try makeContainerSnapshot(
            nativeId: "symlink-dest", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)
        let tar = try fixture.makeTar(fileName: "z", contents: "y\n")
        defer { try? FileManager.default.removeItem(at: tar) }

        do {
            try await fixture.service.putArchive(
                container: container, path: "/link", tarPath: tar, noOverwriteDirNonDir: false)
            Issue.record("expected invalidPath; got success")
        } catch let error as ClientArchiveError {
            guard case .invalidPath = error else {
                Issue.record("expected invalidPath; got \(error)")
                return
            }
        }
    }

    @Test("PUT to a regular file raises invalidPath (route: 400)")
    func putToRegularFile() async throws {
        let fixture = OfflineDestinationFixture(id: "file-dest")
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer()

        let container = try makeContainerSnapshot(
            nativeId: "file-dest", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)
        let tar = try fixture.makeTar(fileName: "z", contents: "y\n")
        defer { try? FileManager.default.removeItem(at: tar) }

        do {
            try await fixture.service.putArchive(
                container: container, path: "/etc/hostname", tarPath: tar, noOverwriteDirNonDir: false)
            Issue.record("expected invalidPath; got success")
        } catch let error as ClientArchiveError {
            guard case .invalidPath = error else {
                Issue.record("expected invalidPath; got \(error)")
                return
            }
        }
    }
}

/// A temporary app-support tree with a created-but-not-started container:
/// a valid ext4 snapshot (containing `/etc/hostname` plus optional symlinks) +
/// dummy init/kernel blobs + `runtime-configuration.json`, and no
/// `rootfs.ext4` (materialised lazily by `putArchive`).
private struct OfflineDestinationFixture {
    let id: String
    let appSupport: URL
    let service: ClientArchiveService

    init(id: String) {
        self.id = id
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-offline-dest-test-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    var containerDir: URL {
        appSupport.appendingPathComponent("containers").appendingPathComponent(id)
    }

    var rootfs: URL { containerDir.appendingPathComponent("rootfs.ext4") }

    func writeCreatedContainer(extraSymlink: (path: String, target: String)? = nil) throws {
        let dir = containerDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let assets = appSupport.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let snapshot = assets.appendingPathComponent("rootfs-snapshot.ext4")
        let formatter = try EXT4.Formatter(FilePath(snapshot.path))
        let hostnameStream = InputStream(data: Data("host\n".utf8))
        hostnameStream.open()
        try formatter.create(
            path: FilePath("/etc/hostname"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: hostnameStream,
            recursion: true)
        if let extraSymlink {
            try formatter.create(
                path: FilePath(extraSymlink.path),
                link: FilePath(extraSymlink.target),
                mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }
        try formatter.close()

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
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:" + String(repeating: "a", count: 64), size: 0)
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

    /// Build a tar containing a single regular file at its root.
    func makeTar(fileName: String, contents: String) throws -> URL {
        let staging = appSupport.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: staging.appendingPathComponent(fileName))
        let tar = appSupport.appendingPathComponent("archive-\(UUID().uuidString).tar")
        try ArchiveUtility.create(tarPath: tar, from: staging)
        return tar
    }
}
