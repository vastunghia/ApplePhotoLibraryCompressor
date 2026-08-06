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

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let created = request.placeholderForCreatedAssetCollection
            placeholder = created
            // Same transaction as the creation, deliberately: an album exists at
            // the top level until it is filed, so doing this in a second call
            // leaves one stranded there if the run is interrupted between them.
            if let folder, let parent = PHCollectionListChangeRequest(for: folder) {
                parent.addChildCollections([created] as NSArray)
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

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: name)
            let created = request.placeholderForCreatedCollectionList
            placeholder = created
            if let parent, let parentRequest = PHCollectionListChangeRequest(for: parent) {
                parentRequest.addChildCollections([created] as NSArray)
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

    /// Ensures `aplc workspace` > `2026-02` > *title*, creating whichever parts
    /// are missing.
    ///
    /// Called only once a command knows it has something to put there: an empty
    /// folder tree in the sidebar would be worse than none.
    public static func ensureWorkspaceAlbum(
        _ title: String,
        inFolderNamed folder: String
    ) async throws -> PHAssetCollection {
        let root = try await ensureFolder(named: WorkspaceLayout.rootFolder)
        let month = try await ensureFolder(named: folder, in: root)
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

        public var description: String {
            switch self {
            case .stagedFileNotHEIC(let u): return "refusing to import non-HEIC file: \(u.path)"
            case .stagedFileMissing(let u): return "staged file is missing: \(u.path)"
            case .creationReturnedNoIdentifier: return "asset was created but no identifier came back"
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
}
