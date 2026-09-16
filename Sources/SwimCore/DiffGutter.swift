/// Pure parser behind the git-panel diff gutter: walks unified-diff lines
/// with the two counters a hunk header seeds (`@@ -oldStart[,n]
/// +newStart[,m] @@`) and produces per-line numbers plus the gutter
/// width. Dependency-free and side-effect-free so it is unit-testable in
/// isolation (Tests/SwimCoreTests/DiffGutterTests.swift) — the panel only
/// stores the result beside its raw `diffLines` (which stay untouched for
/// yank and patch building).
public enum DiffGutter {
    public struct Entry: Equatable {
        /// The file line the row maps to: `+` lines carry the new-file
        /// number, `-` the old-file one, context lines the shared one.
        /// Nil — no number (hunk headers, file headers, metadata).
        public let num: Int?
        public var add: Bool = false
        public var del: Bool = false
    }

    public struct Parsed: Equatable {
        public let entries: [Entry]
        /// Editor formula: max(4, digits of the largest number + 2).
        public let width: Int
    }

    /// Numbering only starts inside a hunk — a commit message line like
    /// `+1 fixed` or ` fixed` is raw text, not diff content. Combined
    /// merge diffs (`diff --cc`, `@@@` headers with two parents and two
    /// marker columns per line) don't map onto the two-counter model —
    /// their hunks get no numbers rather than wrong ones.
    public static func parse<S: StringProtocol>(_ lines: [S]) -> Parsed {
        var entries: [Entry] = []
        entries.reserveCapacity(lines.count)
        var oldNum = 0
        var newNum = 0
        var maxNum = 0
        var inHunk = false
        var inCombined = false
        for line in lines {
            if line.hasPrefix("@@@") {
                inHunk = true
                inCombined = true
                entries.append(Entry(num: nil))
            } else if line.hasPrefix("@@") {
                inHunk = true
                inCombined = false
                let parts = line.split(separator: " ", maxSplits: 3)
                if parts.count >= 3 {
                    oldNum = hunkCounterStart(parts[1]) ?? oldNum
                    newNum = hunkCounterStart(parts[2]) ?? newNum
                }
                entries.append(Entry(num: nil))
            } else if !inHunk || inCombined || line.hasPrefix("---") || line.hasPrefix("+++") {
                entries.append(Entry(num: nil))
            } else if line.hasPrefix("-") {
                entries.append(Entry(num: oldNum, del: true))
                maxNum = max(maxNum, oldNum)
                oldNum += 1
            } else if line.hasPrefix("+") {
                entries.append(Entry(num: newNum, add: true))
                maxNum = max(maxNum, newNum)
                newNum += 1
            } else if line.hasPrefix(" ") {
                entries.append(Entry(num: newNum))
                maxNum = max(maxNum, newNum)
                oldNum += 1
                newNum += 1
            } else {
                entries.append(Entry(num: nil))
            }
        }
        return Parsed(entries: entries, width: max(4, String(maxNum).count + 2))
    }

    /// The line-number counter a hunk-header token starts at: `-12,7` → 12.
    private static func hunkCounterStart<T: StringProtocol>(_ token: T) -> Int? {
        guard token.count > 1 else { return nil }
        // Concrete String avoids the Collection/Sequence `split` overload
        // ambiguity the generic type hits on this toolchain.
        let body = String(token).dropFirst()
        let start = body.split(separator: ",").first.map(String.init) ?? ""
        return Int(start)
    }
}
