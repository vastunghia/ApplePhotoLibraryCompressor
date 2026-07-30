import Foundation
import Photos
import UniformTypeIdentifiers

/// Creates new HEIC assets in the photo library.
///
/// This type is the *only* place in the project that writes to the library, and
/// it is deliberately incapable of destruction: it creates assets and adds them
/// to an album. `PHAssetChangeRequest.deleteAssets`, `contentEditingOutput` and
/// `revertAssetContentToOriginal` appear nowhere in this package — a test in
/// `SafetyInvariantTests` greps the sources to keep it that way.
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
    public static func ensureAlbum(titled title: String) async throws -> PHAssetCollection {
        if let existing = try? PhotoLibraryAccess.findAlbum(titled: title) {
            return existing
        }
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
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
