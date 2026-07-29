import Foundation
import Testing

@testable import socktainer

/// Tests for `ContainerArchiveSerializer`, which serialises per-container
/// asynchronous work so that overlapping `PUT /archive` requests on the same
/// container id cannot race on the ext4 read-modify-swap.
@Suite("ContainerArchiveSerializer")
struct ContainerArchiveSerializerTests {

    @Test("locks for different ids proceed in parallel")
    func differentIdsRunInParallel() async throws {
        let serializer = ContainerArchiveSerializer()
        let recorder = EventRecorder()

        // 8 concurrent locks against 8 unique ids. If the serialiser
        // over-synchronised (e.g. one global lock), the elapsed wall time
        // would be ~8 × the per-body delay; running them in parallel keeps it
        // close to a single delay.
        let delay: Duration = .milliseconds(100)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try await serializer.withLock("id-\(i)") {
                        await recorder.record("enter-\(i)")
                        try await Task.sleep(for: delay)
                        await recorder.record("exit-\(i)")
                    }
                }
            }
            try await group.waitForAll()
        }
        let elapsed = ContinuousClock.now - start

        // Generous ceiling: 4× a single delay lets slow CI still pass while
        // still catching accidental global serialisation (8× or worse).
        #expect(elapsed < delay * 4, "different-id locks should overlap (elapsed=\(elapsed))")

        // Every id must have entered before any exited if they truly ran in
        // parallel — check that at least one enter precedes at least one
        // exit for a different id.
        let events = await recorder.events
        let firstExitIndex = events.firstIndex { $0.hasPrefix("exit-") } ?? events.count
        let entersBeforeFirstExit = events.prefix(firstExitIndex).filter { $0.hasPrefix("enter-") }.count
        #expect(entersBeforeFirstExit >= 2, "at least two ids should enter before any exit fires")
    }

    @Test("locks for the same id run strictly serially in FIFO order")
    func sameIdRunsSerially() async throws {
        let serializer = ContainerArchiveSerializer()
        let recorder = EventRecorder()

        // Launch N tasks against the same id, staggered so their submission
        // order is deterministic (each `await` yields to the actor before the
        // next task is created).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try await serializer.withLock("same-id") {
                        await recorder.record("enter-\(i)")
                        // A small yield lets any accidental concurrent
                        // holder interleave — if serialisation is broken,
                        // enter-N and exit-M would appear out of order.
                        try await Task.sleep(for: .milliseconds(20))
                        await recorder.record("exit-\(i)")
                    }
                }
                // Give the actor a chance to install this task's tail before
                // enqueueing the next, so the FIFO order matches submission.
                await Task.yield()
            }
            try await group.waitForAll()
        }

        let events = await recorder.events
        // Strict serial execution: every enter is immediately followed by
        // its matching exit.
        #expect(events.count == 10)
        for i in stride(from: 0, to: events.count, by: 2) {
            let enter = events[i]
            let exit = events[i + 1]
            #expect(enter.hasPrefix("enter-"))
            #expect(exit.hasPrefix("exit-"))
            #expect(
                enter.dropFirst("enter-".count) == exit.dropFirst("exit-".count),
                "enter and exit must belong to the same body (\(enter) then \(exit))")
        }
    }

    @Test("a throwing body releases the lock so the next caller proceeds")
    func throwingBodyReleasesLock() async throws {
        let serializer = ContainerArchiveSerializer()

        struct BoomError: Error {}

        // First caller throws. If the lock were not released, the second
        // caller would hang forever awaiting the tail task.
        await #expect(throws: BoomError.self) {
            try await serializer.withLock("id") {
                throw BoomError()
            }
        }

        // Second caller must complete promptly.
        let done = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await serializer.withLock("id") {
                    true
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                return false  // timeout sentinel
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        #expect(done == true, "second caller must not be blocked by a prior throw")
    }
}

/// Actor-safe list of ordered event strings for concurrency-order assertions.
private actor EventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
