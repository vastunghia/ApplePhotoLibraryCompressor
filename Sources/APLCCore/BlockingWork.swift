import Foundation

/// Runs work that blocks, on a thread that is allowed to block.
///
/// This exists for one measured reason. ImageIO's HEIC encode ends up inside
/// `VTTileCompressionSessionEncodeTile`, waiting on a semaphore — so a thread
/// doing it is a *blocked* thread, not a busy one. Swift concurrency's
/// cooperative pool has exactly one thread per core and deliberately will not
/// grow to replace a blocked one, so a task group whose children encode fills
/// the pool with blocked threads and **the run deadlocks**: measured on a
/// six-core machine, six concurrent encodes in a task group never returned.
///
/// Two things about that finding are worth keeping, because both were surprises:
///
/// - Putting the encoder behind a lock does **not** help. The threads waiting on
///   the lock are cooperative threads too, so the pool is just as full.
/// - The same work on an ordinary GCD queue is fine. It overcommits, so a
///   blocked thread is replaced rather than waited on.
///
/// So blocking work goes here, and the cooperative threads only ever `await` it.
/// Anything added to this codebase that calls into ImageIO or VideoToolbox from
/// several photos at once has to come through here as well.
public enum BlockingWork {
    private static let queue = DispatchQueue(
        label: "aplc.blocking-work", qos: .userInitiated, attributes: .concurrent
    )

    /// Suspends the calling task, runs `work` on an ordinary thread, resumes.
    ///
    /// How many of these run at once is the caller's business: the queue is
    /// concurrent and unbounded, and `transcode` bounds it by how many photos it
    /// keeps in flight.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
