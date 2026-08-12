import Foundation
import Photos

public enum PhotoLibraryError: Error, CustomStringConvertible {
    case notAuthorized(PHAuthorizationStatus)
    case albumNotFound(String)
    case ambiguousAlbum(String, count: Int)
    case folderNotFound(String)
    case ambiguousFolder(String, count: Int)
    case noOriginalResource(String)
    case resourceUnavailableLocally
    case exportFailed(String)
    case assetsDidNotJoinAlbum(String, asked: Int, landed: Int, wasEditable: Bool)

    public var description: String {
        switch self {
        case .notAuthorized(let s):
            return """
                photo library access not granted (status: \(s.rawValue)).
                Grant your terminal access under System Settings > Privacy & Security > Photos.
                """
        case .albumNotFound(let name):
            return "no album titled \"\(name)\" was found"
        case .ambiguousAlbum(let name, let count):
            return "\(count) albums are titled \"\(name)\"; rename one so the target is unambiguous"
        case .folderNotFound(let name):
            return "no folder named \"\(name)\" was found"
        case .ambiguousFolder(let name, let count):
            return "\(count) folders are named \"\(name)\"; rename one so the target is unambiguous"
        case .noOriginalResource(let id):
            return "asset \(id) has no original photo resource"
        case .resourceUnavailableLocally:
            return "original is not available locally"
        case .exportFailed(let m):
            return "export failed: \(m)"
        case .assetsDidNotJoinAlbum(let title, let asked, let landed, let wasEditable):
            let why = wasEditable
                ? "the library accepted the change and did not make it"
                : "the library will not let this album take new photos"
            return """
                \(landed) of \(asked) photo(s) reached "\(title)": \(why). Nothing was \
                lost — the album is short, not wrong.
                """
        }
    }
}

public enum PhotoLibraryAccess {
    /// Requests read-write access, returning the resulting status.
    ///
    /// Read-write rather than add-only because the tool needs to *read*
    /// originals; it still never deletes or modifies an existing asset.
    @discardableResult
    public static func authorize() async throws -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized { return current }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw PhotoLibraryError.notAuthorized(status) }
        return status
    }

    /// Finds exactly one album with the given title, searching user albums first
    /// and then smart albums. Refuses to guess when several match.
    public static func findAlbum(titled title: String) throws -> PHAssetCollection {
        var matches: [PHAssetCollection] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            result.enumerateObjects { collection, _, _ in
                if collection.localizedTitle == title { matches.append(collection) }
            }
            if !matches.isEmpty { break }
        }
        guard let first = matches.first else { throw PhotoLibraryError.albumNotFound(title) }
        guard matches.count == 1 else {
            throw PhotoLibraryError.ambiguousAlbum(title, count: matches.count)
        }
        return first
    }

    /// The collections directly inside a folder, or at the top of the sidebar
    /// when `parent` is nil.
    private static func children(of parent: PHCollectionList?) -> [PHCollection] {
        let result = parent.map { PHCollection.fetchCollections(in: $0, options: nil) }
            ?? PHCollection.fetchTopLevelUserCollections(with: nil)
        var collections: [PHCollection] = []
        collections.reserveCapacity(result.count)
        result.enumerateObjects { collection, _, _ in collections.append(collection) }
        return collections
    }

    /// Finds exactly one folder with this name inside `parent`, or at the top
    /// level. Refuses to guess when several match, as `findAlbum` does.
    public static func findFolder(named name: String, in parent: PHCollectionList?) throws -> PHCollectionList {
        let matches = children(of: parent)
            .compactMap { $0 as? PHCollectionList }
            .filter { $0.localizedTitle == name }
        guard let first = matches.first else { throw PhotoLibraryError.folderNotFound(name) }
        guard matches.count == 1 else {
            throw PhotoLibraryError.ambiguousFolder(name, count: matches.count)
        }
        return first
    }

    /// Finds exactly one album with this title inside `folder`.
    ///
    /// Scoped to the folder rather than to the library, which is the whole point:
    /// the workspace repeats the same album titles in every month, so a title on
    /// its own stopped identifying anything the day the folders appeared.
    public static func findAlbum(titled title: String, in folder: PHCollectionList) throws -> PHAssetCollection {
        let matches = children(of: folder)
            .compactMap { $0 as? PHAssetCollection }
            .filter { $0.localizedTitle == title }
        guard let first = matches.first else { throw PhotoLibraryError.albumNotFound(title) }
        guard matches.count == 1 else {
            throw PhotoLibraryError.ambiguousAlbum(title, count: matches.count)
        }
        return first
    }

    /// The titles of a folder's children, in the order Photos holds them.
    ///
    /// Order is the point: it is what `WorkspaceLayout.insertionIndex` needs to
    /// work out where a new album belongs, since the order can only be set as the
    /// album is created.
    public static func childTitles(of folder: PHCollectionList) -> [String] {
        children(of: folder).map { $0.localizedTitle ?? "" }
    }

    /// The folder holding a month's albums, wherever it is, or nil.
    ///
    /// Looks in `aplc workspace` > `2019` > `2019-07` first, then falls back to
    /// `aplc workspace` > `2019-07` — where every month folder lived before the
    /// year layer existed, and where those still live, because nothing in this
    /// tool can move a folder out of its parent. Dragging one into its year in
    /// Photos.app is therefore a complete migration: the nested lookup starts
    /// finding it and the fallback simply stops being consulted.
    ///
    /// Both layouts are accepted deliberately and indefinitely. There is no
    /// migration step to write, because there is no supported way to write one.
    public static func findMonthFolder(
        named name: String,
        under root: PHCollectionList
    ) -> PHCollectionList? {
        var parent = root
        for component in WorkspaceLayout.folderPath(forFolderNamed: name) {
            guard let next = try? findFolder(named: component, in: parent) else {
                // Not in the nested place. It may predate it.
                return try? findFolder(named: name, in: root)
            }
            parent = next
        }
        return parent
    }

    /// Resolves `aplc workspace` > `2026` > `2026-02` > *title* without creating
    /// anything.
    public static func findWorkspaceAlbum(
        _ title: String,
        inFolderNamed folder: String
    ) throws -> PHAssetCollection {
        let root = try findFolder(named: WorkspaceLayout.rootFolder, in: nil)
        guard let month = findMonthFolder(named: folder, under: root) else {
            throw PhotoLibraryError.folderNotFound(folder)
        }
        return try findAlbum(titled: title, in: month)
    }

    public static func imageAssets(in collection: PHAssetCollection) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return materialise(PHAsset.fetchAssets(in: collection, options: options))
    }

    /// Every image in the library whose creation date falls in `range`.
    ///
    /// The one read that is not scoped to a named album. Scoping to an album is
    /// this project's substitute for pointing at a scratch library, so widening
    /// it is not done lightly — but an album of candidates cannot be built from
    /// inside an album that does not exist yet. Reading only.
    public static func imageAssets(createdIn range: Range<Date>) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            range.lowerBound as NSDate,
            range.upperBound as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return materialise(PHAsset.fetchAssets(with: .image, options: options))
    }

    /// Local identifiers of the assets already in an album, so a re-run adds
    /// only what is missing.
    public static func identifiers(in collection: PHAssetCollection) -> Set<String> {
        var identifiers: Set<String> = []
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            identifiers.insert(asset.localIdentifier)
        }
        return identifiers
    }

    /// Which of these identifiers still name an asset in the library.
    ///
    /// One fetch for the whole set rather than one each, since the journal can
    /// name every conversion ever made. An asset in Recently Deleted does not
    /// count as surviving: it is on its way out, and it is invisible to the
    /// duplicate check too, so treating it as gone keeps the two agreeing.
    public static func existingIdentifiers(among identifiers: [String]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        var found: Set<String> = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }

    /// The assets these identifiers name, skipping any that no longer exist.
    ///
    /// One fetch rather than one each, as above. Used to turn the identifiers a
    /// creation returned back into assets that can be filed into an album.
    public static func assets(withIdentifiers identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        return materialise(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
    }

    private static func materialise(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// The resource holding the untouched original of a photo.
    public static func originalPhotoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo }
    }

    /// Lifts a `PHAsset` into the plain value type the gate reasons about.
    ///
    /// `isLocallyAvailable` is left `true` here; there is no public API to ask,
    /// and it is answered honestly during export by trying without network first.
    public static func traits(for asset: PHAsset) -> AssetTraits {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo }

        let adjustmentBaseTypes: Set<PHAssetResourceType> = [
            .adjustmentBasePhoto, .adjustmentBasePairedVideo, .adjustmentBaseVideo,
        ]

        return AssetTraits(
            localIdentifier: asset.localIdentifier,
            originalFilename: original?.originalFilename ?? "unknown",
            // `uniformTypeIdentifier` rather than `contentType`: the latter is
            // macOS 26+ and would crash on the macOS 15 machines this targets.
            uniformTypeIdentifier: original?.uniformTypeIdentifier,
            hasAdjustments: asset.hasAdjustments,
            isLivePhoto: asset.playbackStyle == .livePhoto,
            burstIdentifier: asset.burstIdentifier,
            hasPairedVideoResource: resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo },
            hasAdjustmentBaseResource: resources.contains { adjustmentBaseTypes.contains($0.type) },
            isLocallyAvailable: true,
            resourceByteCount: nil,
            creationDate: asset.creationDate
        )
    }
}

/// Result of exporting an original out of the library.
public struct ExportResult: Sendable {
    public let url: URL
    public let byteCount: Int
    /// True when the bytes had to come down from iCloud, which is what the
    /// download budget meters.
    public let wasDownloaded: Bool
}

public actor OriginalExporter {
    /// Cumulative bytes fetched from iCloud during this run.
    public private(set) var downloadedBytes: Int = 0
    /// Ceiling on `downloadedBytes`; nil means downloads are refused outright.
    public let downloadBudgetBytes: Int?

    public init(downloadBudgetBytes: Int?) {
        self.downloadBudgetBytes = downloadBudgetBytes
    }

    public var budgetRemaining: Int? {
        guard let b = downloadBudgetBytes else { return 0 }
        return max(0, b - downloadedBytes)
    }

    /// Writes an asset's original to `destination`.
    ///
    /// Tries strictly offline first. Only if that fails does it consider the
    /// network, and only while the budget holds — so a run can never quietly
    /// pull hundreds of gigabytes down from iCloud.
    public func export(
        resource: PHAssetResource,
        to destination: URL
    ) async throws -> ExportResult {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        do {
            try await write(resource, to: destination, allowNetwork: false)
            let size = fileSize(destination)
            return ExportResult(url: destination, byteCount: size, wasDownloaded: false)
        } catch {
            // Not on disk. Fall through to the metered network path.
        }

        try? FileManager.default.removeItem(at: destination)

        guard let budget = downloadBudgetBytes else {
            throw PhotoLibraryError.resourceUnavailableLocally
        }
        guard downloadedBytes < budget else {
            throw PhotoLibraryError.resourceUnavailableLocally
        }

        try await write(resource, to: destination, allowNetwork: true)
        let size = fileSize(destination)
        downloadedBytes += size
        return ExportResult(url: destination, byteCount: size, wasDownloaded: true)
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    private func write(_ resource: PHAssetResource, to destination: URL, allowNetwork: Bool) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
