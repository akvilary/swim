/// Pure parser behind the editor git gutter: walks the hunk headers of a
/// unified diff produced with `--unified=0` and collects the NEW-file
/// line indices each hunk covers — the lines whose gutter numbers get
/// painted. At `-u0` there are no context lines, so every covered index
/// is an addition or a rewrite; a pure deletion reports `+c,0` and
/// covers nothing (its removed lines have no new-file numbers).
/// Dependency-free and side-effect-free so it is unit-testable in
/// isolation (Tests/SwimCoreTests/HunkLinesTests.swift).
public enum HunkLines {
    /// 0-based new-file line indices covered by the hunks. Headers are
    /// matched strictly (`@@ -a[,b] +c[,d] @@`), so combined merge diffs
    /// (`@@@`, which lack the space right after `@@`) and diff content
    /// lines that merely contain `@@` (they always carry a `+`/`-`/
    /// space marker first) never match.
    public static func changedLines<S: StringProtocol>(_ lines: [S]) -> Set<Int> {
        var result = Set<Int>()
        for line in lines {
            guard line.hasPrefix("@@ ") else { continue }
            // "@@ -a,b +c,d @@ [fn context]" → tokens; the counters are
            // parts 1 and 2 regardless of the trailing context.
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts[1].first == "-", parts[2].first == "+" else { continue }
            guard let (start, count) = counter(parts[2]) else { continue }
            guard count > 0 else { continue }
            let lo = start - 1  // to 0-based
            result.formUnion(lo..<lo + count)
        }
        return result
    }

    /// `+c[,d]` → (c, d ?? 1): an omitted count means one line. A zero
    /// start (`+0,0` of a new-file header side) or a non-numeric token
    /// yields nil — the caller skips it.
    private static func counter<T: StringProtocol>(_ token: T) -> (start: Int, count: Int)? {
        guard token.count > 1 else { return nil }
        // Concrete String avoids the Collection/Sequence `split` overload
        // ambiguity the generic type hits on this toolchain.
        let body = String(token.dropFirst()).split(separator: ",")
        guard let start = body.first.flatMap({ Int($0) }), start >= 1 else { return nil }
        let count = body.count > 1 ? (Int(body[1]) ?? 1) : 1
        return (start, max(0, count))
    }
}
