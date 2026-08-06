import Foundation

/// Where a run keeps its working files, and how long they live.
///
/// Everything in here is scaffolding: the exported original is deleted the
/// moment it has been transcoded, and the staged HEIC has served its purpose as
/// soon as `apply` has copied it into the library. So the default is a fresh
/// temporary directory removed when the run ends, and the user never has to know
/// it existed.
///
/// The exception is deliberate. A pinned root — a directory the user named — is
/// **never** removed, whatever happens. `cleanUp` deletes a tree recursively, so
/// the only tree it may ever touch is one this process created itself; anything
/// looser would put an arbitrary directory one typo away from deletion.
public final class StagingArea {
    public let root: URL

    /// Set only by the initialiser that created the directory. It is the whole
    /// safety argument for `cleanUp`, so it is not settable from outside.
    private let isTemporary: Bool

    /// - Parameter path: nil for a temporary root, removed on `cleanUp`.
    ///   A path for a root of the user's choosing, which is kept.
    public init(pinnedTo path: String? = nil) throws {
        // `isDirectory: true` on both branches, not for tidiness: without it
        // `URL(fileURLWithPath:)` decides by asking the filesystem, so the same
        // directory comes back with a trailing slash once it exists and without
        // one before — and two areas on the same root compare unequal.
        let requested: URL
        if let path {
            requested = URL(fileURLWithPath: path, isDirectory: true)
            isTemporary = false
        } else {
            requested = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("aplc-\(UUID().uuidString)", isDirectory: true)
            isTemporary = true
        }

        // Created *before* the path is canonicalised, and that order is the whole
        // point. Neither `standardizedFileURL` nor `resolvingSymlinksInPath` is a
        // pure function of the string: both consult the filesystem, and both give
        // a different answer for a directory that does not exist yet. Getting
        // this wrong is not cosmetic — `transcode` records staged paths under the
        // root it computed, `apply` matches them against the root *it* computed,
        // and if one ran before the directory existed and the other after, the
        // two disagree by a leading "/private" and `apply` finds nothing staged.
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)

        // Resolved rather than standardized: this is the physical path, which is
        // what every later comparison against a recorded path will be made of.
        root = requested.resolvingSymlinksInPath()
    }

    public var heicDirectory: URL { root.appendingPathComponent("heic") }
    public var originalsDirectory: URL { root.appendingPathComponent("originals") }
    public var compareDirectory: URL { root.appendingPathComponent("compare") }

    /// The root as an argument, for handing to a command this one drives.
    public var forwardedArguments: [String] { ["--staging-dir", root.path] }

    /// Removes a temporary root and does nothing at all to a pinned one.
    ///
    /// Failure is ignored on purpose: the work is already done and recorded in
    /// the ledger, and a directory left behind under `/var/folders` is something
    /// macOS clears by itself. Turning that into an error would fail a run that
    /// actually succeeded.
    public func cleanUp() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
