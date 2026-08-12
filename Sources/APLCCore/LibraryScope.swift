import Foundation
import Photos

/// Reads whether a photo belongs to an iCloud Shared Photo Library.
///
/// **This is the one place in `Sources/` that reads a non-public property, and it
/// was a deliberate exception rather than an oversight.** There is no public API
/// for the fact: the Photos framework headers in the macOS 26.2 SDK contain no
/// occurrence of `Scope` at all, and Photos' scripting dictionary has no notion
/// of it either. The alternatives were to put every copy in the album — which,
/// with most of a library shared, is nearly the same list but invites moving
/// personal photos into a shared library — or to read `ZASSET.ZLIBRARYSCOPE` out
/// of the library's SQLite store. That read is straightforward in itself; what
/// rules it out is what it binds the tool to: a bundle path PhotoKit does not
/// expose, whatever disk-access consent the OS asks for in a given year, and a
/// private schema Apple revises whenever it likes. The property below was
/// measured to work unentitled and to agree with that column, and it degrades to
/// "unknown" instead of to a wrong answer.
///
/// What this does **not** relax: `PHLibraryScopeChangeRequest`,
/// `trashLibraryScopes` and `expungeLibraryScopes` remain banned by
/// `SafetyInvariantTests`, and for the reason recorded there — they act on a
/// whole shared library, so they reach other participants' photos. Nothing here
/// can write anything. A test pins this file as read-only.
public enum LibraryScope {
    /// Whether `asset` participates in an iCloud Shared Photo Library, or `nil`
    /// when the answer cannot be obtained.
    ///
    /// Reached through the runtime rather than by naming the symbol, so a future
    /// macOS that renames or withdraws the property degrades to "unknown" — the
    /// caller then leaves the photo out and says so, which is the safe direction.
    /// Linking against a symbol the SDK does not declare would instead fail to
    /// launch.
    public static func isShared(_ asset: PHAsset) -> Bool? {
        let selector = NSSelectorFromString("participatesInLibraryScope")
        guard asset.responds(to: selector) else { return nil }
        return (asset.value(forKey: "participatesInLibraryScope") as? NSNumber)?.boolValue
    }
}
