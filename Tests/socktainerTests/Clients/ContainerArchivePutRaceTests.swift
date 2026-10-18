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

/// Regression test for the ext4-swap race in `putArchiveFallback` on a
/// non-running container.
///
/// Before the fix, `putArchive` for a non-running container did:
///   1. Export current ext4 → tar
///   2. Build a new ext4 from the exported tar + incoming tar
///   3. `moveItem` the new ext4 over the old
///
/// N concurrent PUTs each snapshot the ext4 in step 1, each build their own
/// new file, and the last `moveItem` wins — every request returns 200, but
/// only the last file survives. The fix serialises the pre-running critical
/// section per container id via `ContainerArchiveSerializer`, so all
/// concurrent files must land.
@Suite("ClientArchiveService.putArchive concurrent PUTs on a non-running container")
struct ContainerArchivePutRaceTests {

    @Test("5 concurrent PUTs on a created container all land in the ext4")
    func concurrentPutsAllLand() async throws {
        let fixture = CreatedContainerRaceFixture(id: "created-race")
        defer { fixture.cleanUp() }
        try fixture.writeCreatedContainer(baseFile: "/etc/hostname", baseContents: "host\n")

        let container = try makeContainerSnapshot(
            nativeId: "created-race", ip: "192.168.65.2", network: "default", labels: [:], status: .stopped)

        let count = 5
        var tars: [URL] = []
        for i in 1...count {
            let tar = try fixture.makeTar(fileName: "injected-\(i).txt", contents: "content-\(i)\n")
            tars.append(tar)
        }
        defer {
            for tar in tars {
                try? FileManager.default.removeItem(at: tar)
            }
        }

        // Fire off N concurrent PUTs. Without the serialiser, the ext4 swap
        // race means at most one of the injected files survives; with it,
        // all N must be present.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for tar in tars {
                group.addTask {
                    try await fixture.service.putArchive(
                        container: container, path: "/", tarPath: tar, noOverwriteDirNonDir: false)
                }
            }
            try await group.waitForAll()
        }

        #expect(FileManager.default.fileExists(atPath: fixture.rootfs.path), "rootfs.ext4 must be materialised on PUT")

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.rootfs.path))
        for i in 1...count {
            let path = "/injected-\(i).txt"
            #expect(reader.exists(FilePath(path)), "file \(path) must survive concurrent PUTs")
            if reader.exists(FilePath(path)) {
                let data = try reader.readFile(at: FilePath(path))
                #expect(String(data: data, encoding: .utf8) == "content-\(i)\n")
            }
        }
        // Pre-existing base image content must survive too.
        #expect(reader.exists(FilePath("/etc/hostname")))
    }
}

/// A temporary app-support tree with a created-but-not-started container:
/// a valid ext4 snapshot + dummy init/kernel blobs + `runtime-configuration.json`,
/// and no `rootfs.ext4`. Duplicates `CreatedContainerFixture` from
/// `ContainerArchivePutCreatedTests` intentionally — the race regression is
/// worth keeping isolated from the sequential regression, both to make bisect
/// obvious and to avoid coupling the two suites' file naming.
private struct CreatedContainerRaceFixture {
    let id: String
    let appSupport: URL
    let service: ClientArchiveService

    init(id: String) {
        self.id = id
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-race-test-\(UUID().uuidString)")
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
