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

/// Regression test for the bug where `PUT /containers/{id}/archive`
/// (`docker cp` before `docker start`) failed with
/// `Abort.404: Rootfs not found` on a created-but-not-started container,
/// because Apple Container only materialises `rootfs.ext4` at start.
///
/// With the fix, `putArchive` provisions the bundle first, then injects the
/// archive offline — so a subsequent start would boot with the file present.
@Suite("ClientArchiveService.putArchive on a created container")
struct ContainerArchivePutCreatedTests {

    @Test("injecting into a created container materialises rootfs.ext4 and writes the file")
    func putArchiveOnCreatedContainer() async throws {
        let fixture = CreatedContainerFixture(id: "created-cp")
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer(baseFile: "/etc/hostname", baseContents: "host\n")

        // No rootfs.ext4 yet — exactly the state that previously 404'd.
        #expect(!FileManager.default.fileExists(atPath: fixture.rootfs.path))

        let container = try makeContainerSnapshot(
            nativeId: "created-cp", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)
        let tar = try fixture.makeTar(fileName: "injected.txt", contents: "copied before start\n")
        defer { try? FileManager.default.removeItem(at: tar) }

        try await fixture.service.putArchive(
            container: container, path: "/", tarPath: tar, noOverwriteDirNonDir: false)

        #expect(FileManager.default.fileExists(atPath: fixture.rootfs.path), "rootfs.ext4 must be materialised on PUT")

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.rootfs.path))
        #expect(reader.exists(FilePath("/injected.txt")), "injected file must be present in the offline rootfs")
        let data = try reader.readFile(at: FilePath("/injected.txt"))
        #expect(String(data: data, encoding: .utf8) == "copied before start\n")
        // The pre-existing base image content must survive the offline edit.
        #expect(reader.exists(FilePath("/etc/hostname")))
    }
}

/// A temporary app-support tree with a created-but-not-started container:
/// a valid ext4 snapshot + dummy init/kernel blobs + `runtime-configuration.json`,
/// and no `rootfs.ext4`.
private struct CreatedContainerFixture {
    let id: String
    let appSupport: URL
    let service: ClientArchiveService

    init(id: String) {
        self.id = id
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-created-test-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    var containerDir: URL {
        appSupport.appendingPathComponent("containers").appendingPathComponent(id)
    }

    var rootfs: URL { containerDir.appendingPathComponent("rootfs.ext4") }

    func writeCreatedContainer(baseFile: String, baseContents: String) throws {
        let dir = containerDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let assets = appSupport.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let snapshot = assets.appendingPathComponent("rootfs-snapshot.ext4")
        let formatter = try EXT4.Formatter(FilePath(snapshot.path))
        let stream = InputStream(data: Data(baseContents.utf8))
        stream.open()
        try formatter.create(path: FilePath(baseFile), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
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
