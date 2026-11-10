/// The `gb` stack — pre-jump positions of the JUMPS a window made
/// (gd, search results, `:N`, counted Ngg/NG), LIFO, capped (the
/// oldest dropped). Pure state: the window owns an instance and the
/// snapshot effects (EditorWindow.recordJumpPosition), the app owns
/// the cross-file unwind (WindowDelegate.requestGoBack). The push
/// doctrine lives at the call sites: push where the jump DECISION is
/// made, never inside the unwind itself — gb pops then jumps, and a
/// push there would ping-pong between two positions forever.
public struct JumpHistory {
    public struct Entry: Equatable {
        public let path: String
        public let line: Int
        public let colUtf16: Int

        public init(path: String, line: Int, colUtf16: Int) {
            self.path = path
            self.line = line
            self.colUtf16 = colUtf16
        }
    }

    private(set) var entries: [Entry] = []
    private let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    /// Appends a return target, dropping the OLDEST entries over the
    /// limit — the recent jumps matter, the deep tail does not.
    public mutating func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// Pops the most recent target; nil when the stack is empty —
    /// gb's "No previous position".
    public mutating func pop() -> Entry? {
        entries.popLast()
    }
}
