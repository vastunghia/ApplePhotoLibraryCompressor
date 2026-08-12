import Foundation

/// What the journal says a month's workspace albums should contain.
///
/// Pure, and deliberately so — the same reason `WorkspaceLayout.insertionIndex`
/// is: the rule *is* the code here, and it is worth being able to test it
/// without a photo library. Everything that needs PhotoKit stays in the command:
/// this type is handed facts and gives back lists.
///
/// It exists because an album fill can be accepted and not made (see
/// `Importer.add`), which leaves a month whose copies are all in the library and
/// whose albums are short. Nothing was lost when that happens, so nothing has to
/// be converted again — the albums simply have to be rebuilt from the record.
public enum RepairPlan {
    /// One conversion the journal records: the JPEG, and the asset it became.
    public struct Conversion: Sendable, Equatable {
        public let source: String
        public let copy: String

        public init(source: String, copy: String) {
            self.source = source
            self.copy = copy
        }
    }

    /// The conversions in a journal, oldest first and one per created asset.
    ///
    /// **The `source == copy` filter is the important line here, not a detail.**
    /// `apply` appends a second `applied` entry for every asset it transferred
    /// keywords, title or caption to, and that entry carries the *new* asset's
    /// identifier in both fields — it records what the copy ended up holding, not
    /// a conversion. Read naively those entries claim each copy is its own
    /// original, and a copy would then be filed into `Compressed Originals`,
    /// which is the album the user deletes from. So they go, and the rule is
    /// pinned by a test.
    ///
    /// Deduplicated by created asset for the same reason, one step milder: the
    /// echo entries repeat an identifier already seen, and a month applied twice
    /// would repeat more.
    public static func conversions(in entries: [LedgerEntry]) -> [Conversion] {
        var seen: Set<String> = []
        var result: [Conversion] = []
        for entry in entries {
            guard entry.outcome == .applied,
                  let copy = entry.createdAssetLocalIdentifier,
                  entry.sourceLocalIdentifier != copy,
                  seen.insert(copy).inserted
            else { continue }
            result.append(Conversion(source: entry.sourceLocalIdentifier, copy: copy))
        }
        return result
    }

    /// One conversion the library still backs, with the two facts only the
    /// library can answer.
    public struct Pair: Sendable {
        public let source: String
        public let copy: String

        /// Where both belong, taken from the **copy's** capture date rather than
        /// the original's.
        ///
        /// The two agree — `apply` files a copy by its original's date and
        /// `Importer.createAsset` writes that date onto the copy — but the copy is
        /// the one that is certainly still there. Deriving the month from the
        /// original would make an already-tidied month unrepairable, which is
        /// exactly the month most likely to need it.
        public let folder: String

        /// False once the user has deleted the JPEG, which is the ordinary end of
        /// this tool's job rather than a problem.
        public let sourceExists: Bool

        /// `nil` when the original is gone or its membership could not be read.
        public let sourceIsShared: Bool?

        public init(
            source: String, copy: String, folder: String,
            sourceExists: Bool, sourceIsShared: Bool?
        ) {
            self.source = source
            self.copy = copy
            self.folder = folder
            self.sourceExists = sourceExists
            self.sourceIsShared = sourceIsShared
        }
    }

    /// What one month's three rebuildable albums should hold.
    ///
    /// `Selected Originals` is absent on purpose: it is `select`'s album, it is
    /// derived from the library rather than from the journal, and re-running
    /// `select` already rebuilds it.
    public struct Month: Sendable, Equatable {
        public let folder: String
        /// For `Compressed Copies`.
        public let copies: [String]
        /// For `Compressed Originals` — only JPEGs still in the library.
        public let originals: [String]
        /// For `Compressed Copies - to Share`.
        public let sharedCopies: [String]
        /// Copies left out of `sharedCopies` because the question could not be
        /// asked. Identifiers rather than a count, so a caller can say how many
        /// of them are genuinely absent from the album instead of alarming about
        /// ones that are already in it.
        public let unknownScopeCopies: [String]
    }

    /// Groups the pairs into months, in folder order.
    ///
    /// Three asymmetries are decided here, and each one matches a choice `apply`
    /// already makes:
    ///
    /// - A copy always counts, because it exists.
    /// - An original counts only while it is still in the library. Once the user
    ///   has deleted the JPEGs there is nothing to gather, and that is the
    ///   finished state rather than a failure.
    /// - A copy joins `sharedCopies` only on a definite yes. Unknown means out,
    ///   because the cost of the two mistakes is not symmetric: a copy missing
    ///   from that album is a photo the user re-shares by hand, while a copy
    ///   wrongly in it is a personal photo published to other people.
    public static func months(_ pairs: [Pair], limitedTo folders: Set<String>? = nil) -> [Month] {
        var order: [String] = []
        var byFolder: [String: [Pair]] = [:]
        for pair in pairs {
            if let folders, !folders.contains(pair.folder) { continue }
            if byFolder[pair.folder] == nil { order.append(pair.folder) }
            byFolder[pair.folder, default: []].append(pair)
        }

        return order.sorted().map { folder in
            let group = byFolder[folder] ?? []
            // One JPEG can have been converted more than once — a fresh staging
            // directory pointed at an already-converted album made two copies of
            // some photos before the duplicate check existed. Both copies are
            // real and both are listed; the original behind them is one photo.
            var seenOriginals: Set<String> = []
            let originals = group
                .filter { $0.sourceExists && seenOriginals.insert($0.source).inserted }
                .map(\.source)
            return Month(
                folder: folder,
                copies: group.map(\.copy),
                originals: originals,
                sharedCopies: group.filter { $0.sourceIsShared == true }.map(\.copy),
                unknownScopeCopies: group.filter { $0.sourceIsShared == nil }.map(\.copy)
            )
        }
    }
}
