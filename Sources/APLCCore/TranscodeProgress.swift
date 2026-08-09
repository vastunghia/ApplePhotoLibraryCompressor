import Foundation

/// The `[ 123/198  62%  ~9m left ]` that goes in front of every conversion line.
///
/// A month of a real library is hours of encoding and two thousand lines, and
/// without this none of them says how far along the run is. The counter goes on
/// the line rather than on a line of its own so that the output still reads the
/// same under `| tee`, and so a log read back afterwards has the position on
/// every line rather than in a status line that scrolled past.
///
/// Time is passed in rather than read, so the estimate can be tested.
public struct TranscodeProgress {
    /// Every photo the run will report on, including the ones the gate refuses
    /// without reading a byte.
    public let total: Int
    /// Of those, the ones that will actually be encoded. The estimate is about
    /// these: a photo refused up front costs no measurable time, so counting it
    /// as work would make the guess optimistic in exactly the months that have
    /// most of them.
    public let encodable: Int

    private let windowSize: Int
    private var done = 0
    private var encodesDone = 0
    /// When the last few encodes were recorded, oldest first.
    private var window: [Date] = []

    public init(total: Int, encodable: Int, windowSize: Int = 20) {
        self.total = total
        self.encodable = encodable
        self.windowSize = max(2, windowSize)
    }

    /// One photo finished and has been recorded.
    public mutating func advance(costAnEncode: Bool, at time: Date) {
        done += 1
        guard costAnEncode else { return }
        encodesDone += 1
        window.append(time)
        if window.count > windowSize { window.removeFirst(window.count - windowSize) }
    }

    /// Seconds per encoded photo lately, or nil until there is enough to say.
    ///
    /// From the last few rather than from the whole run, because a month can
    /// change camera half way through and an average taken from the start would
    /// need another hour to notice.
    ///
    /// **Measured across the window rather than between consecutive samples, and
    /// that is not a detail.** Results are recorded in album order, so a slow
    /// photo parks the ones behind it and several land in the same instant when
    /// it finally arrives. Averaging the gaps would read most of those bursts as
    /// "three photos in no time"; dividing the span of the whole window by its
    /// length cannot be fooled that way.
    public var secondsPerPhoto: Double? {
        guard window.count >= 2, let first = window.first, let last = window.last else { return nil }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return nil }
        return span / Double(window.count - 1)
    }

    /// How much longer the encoding has to run, or nil when it cannot be said.
    public var remaining: TimeInterval? {
        guard let rate = secondsPerPhoto else { return nil }
        let left = encodable - encodesDone
        guard left > 0 else { return nil }
        return rate * Double(left)
    }

    /// What to print in front of the line for the photo just recorded.
    ///
    /// `label` is the month the photo came from. It is repeated on every line
    /// rather than left to the header a run prints per month, because on a long
    /// month the header scrolls out of the window and the lines still on screen
    /// then say nothing about where they belong. Empty in `--album` mode: there
    /// is one album and the user named it himself.
    public func prefix(label: String = "") -> String {
        guard total > 0 else { return "" }
        let width = String(total).count
        let counter = String(format: "%\(width)d/%d", done, total)
        let percent = String(format: "%3d%%", Int((Double(done) / Double(total) * 100).rounded()))
        let head = label.isEmpty ? "" : "\(label)  "
        guard let remaining else { return "[ \(head)\(counter) \(percent) ]" }
        return "[ \(head)\(counter) \(percent)  ~\(Self.duration(remaining)) left ]"
    }

    /// "45s", "9m", "2h 34m". Deliberately coarse: this is an estimate, and
    /// seconds of precision on an hour-long answer would only look authoritative.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
