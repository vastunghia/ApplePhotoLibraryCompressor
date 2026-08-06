import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The text metadata PhotoKit cannot write but Photos.app's scripting interface can.
///
/// Photos exposes `keywords`, `name` (title) and `description` (caption) as
/// read-write properties on `media item`, and maps `id` to the very
/// `localIdentifier` the ledger already records — which is what makes carrying
/// these across to a converted copy possible at all.
public struct AssetTextMetadata: Codable, Equatable, Sendable {
    public var keywords: [String]
    public var title: String?
    public var caption: String?

    public init(keywords: [String] = [], title: String? = nil, caption: String? = nil) {
        self.keywords = keywords
        self.title = title
        self.caption = caption
    }

    public var isEmpty: Bool {
        keywords.isEmpty && (title?.isEmpty ?? true) && (caption?.isEmpty ?? true)
    }
}

public enum PhotosScriptingError: Error, CustomStringConvertible {
    /// The user has not granted the terminal permission to control Photos.
    case automationNotAuthorized
    case photosUnavailable
    // No `albumNotFound`: nothing here looks an album up by name any more, so
    // the error it used to raise can no longer happen.
    case scriptFailed(number: Int, message: String)
    case unexpectedResult(String)

    public var description: String {
        switch self {
        case .automationNotAuthorized:
            return """
                not allowed to control Photos. Grant your terminal access under \
                System Settings > Privacy & Security > Automation > (your terminal) > Photos.
                """
        case .photosUnavailable:
            return "Photos.app could not be reached"
        case .scriptFailed(let number, let message):
            return "Photos scripting error \(number): \(message)"
        case .unexpectedResult(let detail):
            return "unexpected reply from Photos: \(detail)"
        }
    }

    /// True when the failure is about access or availability rather than data.
    ///
    /// Callers degrade on these — conversion must not depend on Apple Events.
    public var isEnvironmental: Bool {
        switch self {
        case .automationNotAuthorized, .photosUnavailable: return true
        default: return false
        }
    }
}

/// The only place in the project that speaks to Photos.app over Apple Events.
///
/// It can read the three text properties and set them on assets we created.
/// It deliberately cannot delete, remove or duplicate anything — a test in
/// `SafetyInvariantTests` checks the generated script text for those verbs.
public enum PhotosScripting {
    /// Assets per generated script. Bounded so one enormous album does not
    /// produce a script big enough to choke the compiler.
    static let batchSize = 150

    // MARK: - Reading

    /// Reads keywords, title and caption for the given assets, keyed by
    /// `localIdentifier`.
    ///
    /// Addressed one asset at a time rather than by walking an album, because an
    /// album title stopped identifying an album: the workspace repeats
    /// "Selected Originals" and "Compressed Copies" in every month's folder, and
    /// Photos' `albums` is a flat list "in no specific order", so a lookup by
    /// name would silently answer about the wrong month. Identifiers are exact,
    /// and the write path has always used them.
    ///
    /// An asset Photos cannot produce is simply absent from the result. That is
    /// not the same as the whole read failing, which throws — the caller must
    /// keep the two apart, since "no keywords" and "could not ask" mean opposite
    /// things to `Transcoder`.
    @MainActor
    public static func readTextMetadata(
        forIdentifiers identifiers: [String]
    ) throws -> [String: AssetTextMetadata] {
        guard !identifiers.isEmpty else { return [:] }

        var result: [String: AssetTextMetadata] = [:]
        for chunk in stride(from: 0, to: identifiers.count, by: batchSize).map({
            Array(identifiers[$0..<min($0 + batchSize, identifiers.count)])
        }) {
            let descriptor = try run(readScript(for: chunk))
            result.merge(try parseReadResult(descriptor)) { _, new in new }
        }
        return result
    }

    static func readScript(for identifiers: [String]) -> String {
        var body = ""
        for identifier in identifiers {
            // Each asset in its own `try`: one that Photos has lost must not
            // cost us the other hundred and forty-nine in the batch.
            body += """
                    try
                        set m to media item id \(literal(identifier))
                        set kw to {}
                        try
                            set kw to keywords of m
                            if kw is missing value then set kw to {}
                        end try
                        set nm to ""
                        try
                            set nm to name of m
                            if nm is missing value then set nm to ""
                        end try
                        set ds to ""
                        try
                            set ds to description of m
                            if ds is missing value then set ds to ""
                        end try
                        set end of outList to {id of m, kw, nm, ds}
                    end try

                """
        }

        return """
            tell application "Photos"
                set outList to {}
            \(body)    return outList
            end tell
            """
    }

    static func parseReadResult(_ descriptor: NSAppleEventDescriptor) throws -> [String: AssetTextMetadata] {
        var result: [String: AssetTextMetadata] = [:]
        // AppleScript lists are 1-based.
        for index in 1...max(descriptor.numberOfItems, 0) where descriptor.numberOfItems > 0 {
            guard let row = descriptor.atIndex(index), row.numberOfItems >= 4,
                  let identifier = row.atIndex(1)?.stringValue
            else {
                throw PhotosScriptingError.unexpectedResult("malformed row at index \(index)")
            }

            var keywords: [String] = []
            if let list = row.atIndex(2), list.numberOfItems > 0 {
                for k in 1...list.numberOfItems {
                    if let value = list.atIndex(k)?.stringValue, !value.isEmpty {
                        keywords.append(value)
                    }
                }
            }

            // Empty string stands in for "absent" so the script needs no
            // missing-value handling on the way back.
            let title = row.atIndex(3)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let caption = row.atIndex(4)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

            result[identifier] = AssetTextMetadata(keywords: keywords, title: title, caption: caption)
        }
        return result
    }

    // MARK: - Writing

    /// Applies metadata to assets addressed by `localIdentifier`.
    ///
    /// Returns the identifiers Photos refused, so the caller can report them
    /// rather than assume success. One bad asset does not abort the batch.
    @discardableResult
    @MainActor
    public static func writeTextMetadata(_ assignments: [String: AssetTextMetadata]) throws -> [String] {
        let entries = assignments.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        guard !entries.isEmpty else { return [] }

        var failures: [String] = []
        for chunk in stride(from: 0, to: entries.count, by: batchSize).map({
            Array(entries[$0..<min($0 + batchSize, entries.count)])
        }) {
            let descriptor = try run(writeScript(for: chunk))
            if descriptor.numberOfItems > 0 {
                for index in 1...descriptor.numberOfItems {
                    if let identifier = descriptor.atIndex(index)?.stringValue {
                        failures.append(identifier)
                    }
                }
            }
        }
        return failures
    }

    static func writeScript(for entries: [(key: String, value: AssetTextMetadata)]) -> String {
        var body = ""
        for (identifier, metadata) in entries {
            var sets: [String] = []
            if !metadata.keywords.isEmpty {
                let list = metadata.keywords.map(literal).joined(separator: ", ")
                sets.append("            set keywords of m to {\(list)}")
            }
            if let title = metadata.title, !title.isEmpty {
                sets.append("            set name of m to \(literal(title))")
            }
            if let caption = metadata.caption, !caption.isEmpty {
                sets.append("            set description of m to \(literal(caption))")
            }
            guard !sets.isEmpty else { continue }

            body += """
                    try
                        set m to media item id \(literal(identifier))
                \(sets.joined(separator: "\n"))
                    on error
                        set end of failed to \(literal(identifier))
                    end try

                """
        }

        return """
            tell application "Photos"
                set failed to {}
            \(body)    return failed
            end tell
            """
    }

    // MARK: - Importing

    /// Hands files to Photos to import, and returns the identifiers it made.
    ///
    /// This is the *second* way into the library, and the only one that is not
    /// `PHAssetCreationRequest`. It exists because an asset created through
    /// PhotoKit belongs to no import session — `ZASSET.ZIMPORTSESSION` is null —
    /// so it never appears under Collections > Other > Imports, and carries no
    /// "added by" attribution. Photos' own import sets both.
    ///
    /// Two deliberate choices, both of which the caller depends on:
    ///
    /// - **No `into` parameter**, though the dictionary offers one. It takes an
    ///   `album` object, and album titles stopped identifying albums when the
    ///   workspace began repeating them per month. The caller adds the returned
    ///   assets to the album through PhotoKit instead, by identifier.
    /// - **`skip check duplicates` is true.** `DuplicateCheck` has already asked
    ///   the library and, where it was uncertain, asked the user. Letting Photos
    ///   apply a second and different rule would mean an import silently coming
    ///   back empty, which reads exactly like a failure.
    ///
    /// Photos takes the asset's filename from the file on disk, so the caller
    /// must name it before calling. Nothing here can set it afterwards.
    /// What one imported file came back as.
    public struct ImportedItem: Sendable, Equatable {
        public let identifier: String
        /// Photos' own `filename`, which is the name of the file we handed it.
        /// Carried so the caller can match results to inputs without trusting
        /// the order of the reply.
        public let filename: String
    }

    /// Hands *every* file to Photos in as few `import` calls as possible.
    ///
    /// Batching is not a performance nicety here: one `import` is one import
    /// session, so a call per photo would fill Collections > Other > Imports
    /// with one single-photo event per conversion — worse than the PhotoKit
    /// path, which at least leaves that view alone. A month's conversion should
    /// read as one import, because that is what it was.
    ///
    /// The chunking still applies, so a run longer than `batchSize` photos
    /// becomes that many sessions rather than one. That is the honest cost of
    /// not handing AppleScript a list literal of unbounded length.
    @MainActor
    public static func importFiles(_ urls: [URL]) throws -> [ImportedItem] {
        guard !urls.isEmpty else { return [] }

        var items: [ImportedItem] = []
        for chunk in stride(from: 0, to: urls.count, by: batchSize).map({
            Array(urls[$0..<min($0 + batchSize, urls.count)])
        }) {
            let descriptor = try run(importScript(for: chunk))
            guard descriptor.numberOfItems > 0 else { continue }
            for index in 1...descriptor.numberOfItems {
                guard let row = descriptor.atIndex(index), row.numberOfItems >= 2,
                      let identifier = row.atIndex(1)?.stringValue,
                      let filename = row.atIndex(2)?.stringValue
                else {
                    throw PhotosScriptingError.unexpectedResult(
                        "import returned a row without an id and a filename")
                }
                items.append(ImportedItem(identifier: identifier, filename: filename))
            }
        }
        return items
    }

    static func importScript(for urls: [URL]) -> String {
        // The file list is built outside the tell block: `POSIX file` is a
        // language construct rather than one of Photos' verbs, and it reads
        // more predictably where Photos' own terminology is not in scope.
        let files = urls.map { "POSIX file \(literal($0.path))" }.joined(separator: ", ")
        return """
            set theFiles to {\(files)}
            tell application "Photos"
                set outList to {}
                set imported to import theFiles skip check duplicates true
                repeat with m in imported
                    set end of outList to {id of m, filename of m}
                end repeat
                return outList
            end tell
            """
    }

    // MARK: - Plumbing

    /// Renders a Swift string as an AppleScript string literal.
    ///
    /// Backslash must be escaped before the quote, or the quote's own escape
    /// would then be double-escaped. Raw newlines are a syntax error inside an
    /// AppleScript literal, so they become escape sequences — captions really
    /// do contain them.
    static func literal(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\r\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Must run on the main thread, and the isolation is what enforces it.
    ///
    /// While waiting for Photos to reply, AppleScript calls the Apple Event
    /// "active proc", which is `WaitNextEvent` on the *calling* thread's Carbon
    /// event loop. Only the main thread has one that receives the reply, so off
    /// the main thread the send blocks in `mach_msg` forever.
    ///
    /// This bites only once PhotoKit has been touched — verified on macOS 15.7.7:
    /// with Photos.framework uninitialised the same call returns normally from a
    /// background thread, which is why the deadlock looks intermittent. `aplc`
    /// always authorises the library first, so for us it is deterministic.
    @MainActor
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        #if canImport(AppKit)
        guard let script = NSAppleScript(source: source) else {
            throw PhotosScriptingError.unexpectedResult("script would not compile")
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            switch number {
            // -1743: the user declined, or has not yet granted, Automation access.
            case -1743, -10004:
                throw PhotosScriptingError.automationNotAuthorized
            // -600 / -609: Photos is not running or the connection went away.
            case -600, -609:
                throw PhotosScriptingError.photosUnavailable
            default:
                throw PhotosScriptingError.scriptFailed(number: number, message: message)
            }
        }
        return descriptor
        #else
        throw PhotosScriptingError.photosUnavailable
        #endif
    }
}
