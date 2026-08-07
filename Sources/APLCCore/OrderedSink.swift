import Foundation

/// Puts results that arrive out of order back into order.
///
/// `transcode` converts several photos at once, so they finish in whatever order
/// the encoder and the pictures decide. The journal and the progress lines are
/// still emitted in album order, which is what makes two runs of the same month
/// comparable line by line — so completions are held here until the index the
/// caller is waiting for turns up.
///
/// Nothing bounds how much it holds: one slow photo can park every later one.
/// That is the accepted cost of the ordering, and it is cheap because what is
/// held is a small value per photo — the encoded files are on disk either way.
public struct OrderedSink<Value> {
    /// Completions that arrived before their turn.
    private var waiting: [Int: Value] = [:]
    /// The index that has to arrive before anything can be released.
    public private(set) var nextIndex: Int

    public init(startingAt index: Int = 0) {
        nextIndex = index
    }

    /// How many completions are parked behind a slower one.
    public var heldCount: Int { waiting.count }

    /// Accepts one completion and returns everything that is now in order,
    /// which is empty whenever an earlier index is still outstanding.
    ///
    /// A repeated index is a caller bug rather than a state to recover from, so
    /// it is a precondition: silently dropping one would lose a journal line,
    /// and silently replacing one would record the wrong photo.
    public mutating func insert(_ value: Value, at index: Int) -> [Value] {
        precondition(index >= nextIndex, "index \(index) was already released")
        precondition(waiting[index] == nil, "index \(index) was inserted twice")
        waiting[index] = value

        var ready: [Value] = []
        while let next = waiting.removeValue(forKey: nextIndex) {
            ready.append(next)
            nextIndex += 1
        }
        return ready
    }
}
