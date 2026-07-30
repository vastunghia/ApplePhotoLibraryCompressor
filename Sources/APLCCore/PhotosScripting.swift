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
    case albumNotFound(String)
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
        case .albumNotFound(let name):
            return "Photos has no album titled \"\(name)\""
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

    /// Reads keywords, title and caption for every media item in an album,
    /// keyed by `localIdentifier`.
    @MainActor
    public static func readTextMetadata(inAlbumTitled album: String) throws -> [String: AssetTextMetadata] {
        let descriptor = try run(readScript(album: album))
        return try parseReadResult(descriptor)
    }

    static func readScript(album: String) -> String {
        """
        tell application "Photos"
            set theAlbum to missing value
            repeat with a in albums
                if name of a is \(literal(album)) then
                    set theAlbum to a
                    exit repeat
                end if
            end repeat
            if theAlbum is missing value then error "aplc:album-not-found" number 8001
            set outList to {}
            repeat with m in (get media items of theAlbum)
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
            end repeat
            return outList
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
            case 8001:
                throw PhotosScriptingError.albumNotFound(message)
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
