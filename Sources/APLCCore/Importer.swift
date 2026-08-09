import Foundation
import Photos
import UniformTypeIdentifiers

/// Creates new HEIC assets in the photo library.
///
/// This type is the *only* place in the project that writes to the library, and
/// it is deliberately incapable of destruction: it creates assets, albums and
/// folders, and puts things into them. `PHAssetChangeRequest.deleteAssets`,
/// `contentEditingOutput` and `revertAssetContentToOriginal` appear nowhere in
/// this package — a test in `SafetyInvariantTests` greps the sources to keep it
/// that way, and the same test bans the calls that would unmake a folder.
///
/// Everything here is therefore additive and one-way. That is the trade the user
/// chose: nothing can be lost, and nothing can be tidied away either.
public enum Importer {
    /// Metadata carried from the source asset onto the new one.
    ///
    /// PhotoKit exposes no write API for title, caption or keywords, so those
    /// genuinely cannot be transferred. The CLI reports this rather than
    /// pretending the copy is complete.
    public struct CarriedMetadata: Sendable {
        public var creationDate: Date?
        public var location: CLLocation?
        public var isFavorite: Bool
        public var isHidden: Bool

        public init(from asset: PHAsset) {
            self.creationDate = asset.creationDate
            self.location = asset.location
            self.isFavorite = asset.isFavorite
            self.isHidden = asset.isHidden
        }
    }

    /// Fetches the destination album, creating it if it does not exist yet.
    ///
    /// `folder` nil means the top of the sidebar, which is where an album named
    /// by `--album` or `--dest-album` goes.
    public static func ensureAlbum(
        titled title: String,
        in folder: PHCollectionList? = nil
    ) async throws -> PHAssetCollection {
        if let folder {
            if let existing = try? PhotoLibraryAccess.findAlbum(titled: title, in: folder) {
                return existing
            }
        } else if let existing = try? PhotoLibraryAccess.findAlbum(titled: title) {
            return existing
        }

        // Worked out before the change block, which cannot fetch. `apply` is
        // sequential and is the only writer, so nothing can slip into the folder
        // in between.
        let position = folder.map {
            WorkspaceLayout.insertionIndex(
                for: title, among: PhotoLibraryAccess.childTitles(of: $0)
            )
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let created = request.placeholderForCreatedAssetCollection
            placeholder = created
            // Same transaction as the creation, deliberately: an album exists at
            // the top level until it is filed, so doing this in a second call
            // leaves one stranded there if the run is interrupted between them.
            //
            // Inserted rather than appended, because Photos keeps a folder's
            // children in the order they arrived and this tool cannot reorder
            // them afterwards: the call that would is forbidden. Placing the
            // album correctly as it is born is the only chance there is.
            if let folder, let position, let parent = PHCollectionListChangeRequest(for: folder) {
                parent.insertChildCollections(
                    [created] as NSArray, at: IndexSet(integer: position)
                )
            }
        }
        guard let id = placeholder?.localIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(
                  withLocalIdentifiers: [id], options: nil
              ).firstObject
        else {
            throw PhotoLibraryError.albumNotFound(title)
        }
        return created
    }

    /// Fetches a folder, creating it if it does not exist yet.
    ///
    /// Creating one is as far as this goes. `PHCollectionListChangeRequest` can
    /// also delete a folder and empty it of albums, and those calls are on the
    /// forbidden list in `SafetyInvariantTests` — so a folder this tool makes is
    /// as one-way as an album it fills, and for the same reason.
    public static func ensureFolder(
        named name: String,
        in parent: PHCollectionList? = nil
    ) async throws -> PHCollectionList {
        if let existing = try? PhotoLibraryAccess.findFolder(named: name, in: parent) {
            return existing
        }

        // As in `ensureAlbum`, and for the same reason: a folder cannot be moved
        // once it exists, so its place among its siblings is settled now or never.
        // Only inside the workspace — the top level of the sidebar is the user's,
        // and the root folder goes wherever Photos puts it.
        let position = parent.map {
            WorkspaceLayout.folderInsertionIndex(
                for: name, among: PhotoLibraryAccess.childTitles(of: $0)
            )
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: name)
            let created = request.placeholderForCreatedCollectionList
            placeholder = created
            if let parent, let position, let parentRequest = PHCollectionListChangeRequest(for: parent) {
                parentRequest.insertChildCollections(
                    [created] as NSArray, at: IndexSet(integer: position)
                )
            }
        }
        guard let id = placeholder?.localIdentifier,
              let created = PHCollectionList.fetchCollectionLists(
                  withLocalIdentifiers: [id], options: nil
              ).firstObject
        else {
            throw PhotoLibraryError.folderNotFound(name)
        }
        return created
    }

    /// Ensures `aplc workspace` > `2026` > `2026-02` > *title*, creating whichever
    /// parts are missing.
    ///
    /// Called only once a command knows it has something to put there: an empty
    /// folder tree in the sidebar would be worse than none.
    ///
    /// **The existing folder is looked for before anything is created, and the
    /// order is the whole correctness of the year layer.** Month folders made
    /// before that layer sit directly under the root and cannot be moved there
    /// from here, so creating first would give a month two folders — an empty
    /// `2019` beside a perfectly good `2019-07` — and split one month's albums
    /// across both, permanently, since neither can be removed. `findMonthFolder`
    /// answers for both layouts; only when it finds nothing at all is any folder
    /// made.
    public static func ensureWorkspaceAlbum(
        _ title: String,
        inFolderNamed folder: String
    ) async throws -> PHAssetCollection {
        let root = try await ensureFolder(named: WorkspaceLayout.rootFolder)
        let month: PHCollectionList
        if let existing = PhotoLibraryAccess.findMonthFolder(named: folder, under: root) {
            month = existing
        } else {
            var parent = root
            for component in WorkspaceLayout.folderPath(forFolderNamed: folder) {
                parent = try await ensureFolder(named: component, in: parent)
            }
            month = parent
        }
        return try await ensureAlbum(titled: title, in: month)
    }

    /// Adds photos that are already in the library to an album.
    ///
    /// An album holds references, so this does not touch the photos themselves
    /// and cannot lose anything. It is nonetheless a one-way door: the inverse
    /// call is on the forbidden list in `SafetyInvariantTests`, so no command in
    /// this tool can ever take a photo back out. Filling the wrong album is
    /// undone by hand in Photos.app, and the CLI says so before it writes.
    public static func add(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    public enum ImportError: Error, CustomStringConvertible {
        case stagedFileNotHEIC(URL)
        case stagedFileMissing(URL)
        case creationReturnedNoIdentifier
        case photosImportedNothing(String)
        case photosImportedMoreThanOne(String, count: Int)
        case createdAssetNotFound(String)

        public var description: String {
            switch self {
            case .stagedFileNotHEIC(let u): return "refusing to import non-HEIC file: \(u.path)"
            case .stagedFileMissing(let u): return "staged file is missing: \(u.path)"
            case .creationReturnedNoIdentifier: return "asset was created but no identifier came back"
            case .photosImportedNothing(let name):
                return "Photos imported nothing for \(name)"
            case .photosImportedMoreThanOne(let name, let count):
                return "Photos returned \(count) assets for the one file \(name)"
            case .createdAssetNotFound(let id):
                return "Photos reported creating \(id), but it cannot be fetched"
            }
        }
    }

    /// Adds a staged HEIC to the library as a brand new asset in `album`.
    ///
    /// Returns the new asset's local identifier so the ledger can record the
    /// link between old and new.
    @discardableResult
    public static func createAsset(
        fromStagedHEIC staged: URL,
        originalFilename: String,
        metadata: CarriedMetadata,
        into album: PHAssetCollection
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ImportError.stagedFileMissing(staged)
        }
        // Re-check the file type at the last possible moment: whatever earlier
        // phases believed, only an actual HEIC gets written into the library.
        let facts = try ImageProbe.probe(staged)
        guard let uti = facts.typeIdentifier, UTType(uti) == .heic else {
            throw ImportError.stagedFileNotHEIC(staged)
        }

        var placeholder: PHObjectPlaceholder?

        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()

            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalFilename
            // Copy rather than move: staging stays intact as a safety net so a
            // failed run leaves the converted files recoverable on disk.
            options.shouldMoveFile = false

            creation.addResource(with: .photo, fileURL: staged, options: options)
            creation.creationDate = metadata.creationDate
            creation.location = metadata.location
            creation.isFavorite = metadata.isFavorite
            creation.isHidden = metadata.isHidden

            guard let created = creation.placeholderForCreatedAsset else { return }
            placeholder = created

            if let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([created] as NSArray)
            }
        }

        guard let identifier = placeholder?.localIdentifier else {
            throw ImportError.creationReturnedNoIdentifier
        }
        return identifier
    }

    // MARK: - The same thing, through Photos.app

    /// Adds a staged HEIC by asking Photos.app to import it, rather than by
    /// creating the asset ourselves.
    ///
    /// The difference this buys is entirely in what Photos records about the
    /// asset afterwards: an import session, so the copy appears under
    /// Collections > Other > Imports beside its neighbours, and an "added by"
    /// attribution. `PHAssetCreationRequest` sets neither, and PhotoKit exposes
    /// no way to set them — measured, not assumed: nothing in the framework's
    /// headers or its symbol table mentions either field.
    ///
    /// What it costs is that Photos, not us, reads the two facts that identify a
    /// converted copy. Both are given back afterwards rather than hoped for:
    ///
    /// - **The filename** comes from the file on disk, so the staged file is
    ///   copied to one named `originalFilename` first. The copy is what makes
    ///   this safe to do inside a staging directory whose files are named by
    ///   local identifier.
    /// - **The capture date** comes from the file's EXIF, which the transcoder
    ///   does preserve — but Photos' own date is authoritative and can differ
    ///   from it, for a date corrected by hand or a photo that never had one. So
    ///   it is set explicitly afterwards, exactly as `createAsset` sets it, and
    ///   the pairing rule keeps the same guarantee on both paths.
    ///
    /// The album is joined through PhotoKit rather than through the `into`
    /// parameter Photos offers, because that one takes an album by object and
    /// album titles no longer identify albums.
    /// Copies a staged file to one named the way the asset should be named, and
    /// returns where it put it.
    ///
    /// Separate from the import itself because the import is batched: every file
    /// in a run is prepared first, then all of them are handed over at once.
    public static func prepareForPhotosImport(
        stagedHEIC staged: URL,
        originalFilename: String
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ImportError.stagedFileMissing(staged)
        }
        // Re-check the file type at the last possible moment, exactly as the
        // PhotoKit path does: only an actual HEIC gets offered to the library.
        let facts = try ImageProbe.probe(staged)
        guard let uti = facts.typeIdentifier, UTType(uti) == .heic else {
            throw ImportError.stagedFileNotHEIC(staged)
        }

        // A directory of its own per asset: the staged stem is the local
        // identifier and so unique, whereas two photos from different months can
        // share an original filename and would otherwise collide here.
        let directory = staged.deletingLastPathComponent()
            .appendingPathComponent("import", isDirectory: true)
            .appendingPathComponent(staged.deletingPathExtension().lastPathComponent,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let named = directory.appendingPathComponent(originalFilename)
        if FileManager.default.fileExists(atPath: named.path) {
            try FileManager.default.removeItem(at: named)
        }
        // Copy, never move — the staged file stays as the safety net, the same
        // rule `shouldMoveFile = false` states on the PhotoKit path.
        try FileManager.default.copyItem(at: staged, to: named)
        return named
    }

    /// Asks Photos to import every prepared file in one go, and says which
    /// identifier each filename became.
    ///
    /// Matched by filename rather than by position: Photos' reply carries each
    /// item's `filename`, and nothing in the dictionary promises the order of
    /// the list it returns. A filename that comes back twice is refused rather
    /// than guessed at — mapping the wrong identifier to a photo would put
    /// another photo's metadata on it.
    public static func importViaPhotosApp(_ files: [URL]) async throws -> [String: String] {
        guard !files.isEmpty else { return [:] }
        let items = try await MainActor.run { try PhotosScripting.importFiles(files) }

        var byFilename: [String: String] = [:]
        for item in items {
            if byFilename.updateValue(item.identifier, forKey: item.filename) != nil {
                throw ImportError.photosImportedMoreThanOne(item.filename, count: 2)
            }
        }
        return byFilename
    }

    /// Finishes one asset Photos has just imported: sets what PhotoKit will
    /// accept, and files it in its album.
    ///
    /// The capture date is the reason this step is not optional. Photos reads it
    /// from the file's EXIF, which the transcoder does preserve — but Photos' own
    /// date is authoritative and can differ, for a date corrected by hand or a
    /// photo that never had one in the file. Setting it explicitly keeps the
    /// pairing rule identical on both import routes.
    public static func adoptImportedAsset(
        _ identifier: String,
        metadata: CarriedMetadata,
        into album: PHAssetCollection
    ) async throws {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else {
            throw ImportError.createdAssetNotFound(identifier)
        }
        try await applyMetadata(metadata, to: asset)
        try await add([asset], to: album)
    }

    /// Sets on an existing asset the four properties PhotoKit will accept.
    ///
    /// Only reachable from the Photos.app import path, which has no way to pass
    /// them at creation time. These are the whole writable surface of
    /// `PHAssetChangeRequest` bar `contentEditingOutput`, which is forbidden here
    /// because it replaces a rendition rather than adding one.
    static func applyMetadata(_ metadata: CarriedMetadata, to asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.creationDate = metadata.creationDate
            request.location = metadata.location
            request.isFavorite = metadata.isFavorite
            request.isHidden = metadata.isHidden
        }
    }
}
