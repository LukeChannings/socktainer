import Foundation

/// Serialises asynchronous work per container id.
///
/// Multiple concurrent callers holding the lock for the **same** id run one
/// at a time, in FIFO order. Callers holding the lock for **different** ids
/// proceed in parallel — the serialiser only synchronises within a single
/// container.
///
/// ## Why this exists
///
/// `PUT /containers/{id}/archive` on a non-running container goes through a
/// full read-modify-swap of `rootfs.ext4` (`ClientArchiveService.putArchiveFallback`):
///
/// 1. export the current ext4 to a tar,
/// 2. build a fresh ext4 from that tar plus the incoming tar,
/// 3. `moveItem` the new file over the old one.
///
/// Two overlapping requests each snapshot the ext4 at step 1, each build their
/// own new file, and the second `moveItem` wins — silently obliterating the
/// first PUT's contribution while both return `200`. Serialising the whole
/// PUT critical section per container id closes the race without leaking
/// implementation detail into the callers.
///
/// This generalises the in-flight-task pattern that
/// `ContainerRootfsProvisioner` uses to deduplicate `ensureRootfs` calls: the
/// provisioner needs *deduplication* (a second caller shares the first's
/// result), whereas this serialiser needs *strict FIFO ordering* (each caller
/// runs its own body, in order). They compose — a PUT that provisions the
/// rootfs then swaps it holds the serialiser lock across both steps.
actor ContainerArchiveSerializer {
    /// Monotonic slot identifier used to safely clean up the tail map entry
    /// only when no later caller has replaced us as the tail.
    private var nextSlot: UInt64 = 0

    /// The tail of the wait chain per container id. New callers await
    /// `tail[id]?.task` before running, then install their own slot so the
    /// next caller waits for them in turn.
    private var tail: [String: (slot: UInt64, task: Task<Void, Never>)] = [:]

    init() {}

    /// Run `body` while holding the lock for `id`.
    ///
    /// - Any prior in-flight body for the same id runs to completion first
    ///   (whether it returns or throws — the lock is always released).
    /// - Bodies for other ids proceed in parallel.
    /// - The generic result of `body` is returned to the caller unchanged;
    ///   thrown errors propagate unchanged.
    func withLock<T: Sendable>(
        _ id: String,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        nextSlot &+= 1
        let mySlot = nextSlot
        let prior = tail[id]?.task

        // A single-shot release signal: this task completes when `body` does,
        // and later callers await it as their "prior" gate.
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let myTask = Task<Void, Never>.detached {
            _ = await prior?.value
            for await _ in releaseStream { break }
        }
        tail[id] = (mySlot, myTask)

        // Wait for the previous holder to release before entering the
        // critical section. Actor reentrance means calls for *other* ids
        // continue to be serviced during this suspension.
        _ = await prior?.value

        // `release` must run exactly once, on every exit path.
        var released = false
        func release() {
            guard !released else { return }
            released = true
            releaseContinuation.yield(())
            releaseContinuation.finish()
            // Only clear the tail if we are still the tail — otherwise a
            // later caller has already chained onto us and needs the entry
            // to stay.
            if tail[id]?.slot == mySlot {
                tail[id] = nil
            }
        }
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
