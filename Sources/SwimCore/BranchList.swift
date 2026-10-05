/// Pure parser behind the branch picker's `git for-each-ref` listing:
/// `--format=%(refname:short)%00%(committerdate:relative)%00%(HEAD)`
/// — one branch per line, fields NUL-separated. The order is git's own
/// (`--sort=-committerdate`: the branch with the newest last commit
/// first); swim never re-sorts. Dependency-free and side-effect-free
/// so it is unit-testable in isolation
/// (Tests/SwimCoreTests/BranchListTests.swift).
public enum BranchList {
    public struct Entry: Equatable {
        /// Short branch name (refname:short — "feature/x", not
        /// "refs/heads/feature/x").
        public let name: String
        /// Relative committerdate ("2 hours ago") — display-only.
        public let lastCommit: String
        /// True on the branch HEAD points at (`%(HEAD)` = "*").
        public let isCurrent: Bool
    }

    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // The HEAD field is empty on non-current branches (git also
            // pads it with a space on some versions) — keep empty
            // subsequences so the field count stays honest.
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            entries.append(Entry(
                name: String(fields[0]),
                lastCommit: String(fields[1]),
                isCurrent: fields[2].trimmingCharacters(in: .whitespaces) == "*"))
        }
        return entries
    }

    /// The for-each-ref selector for a picker query: a contains-match
    /// on the branch name, paired with the command's `--ignore-case`.
    /// `**/` crosses path components — a lone `*` (WM_PATHNAME) would
    /// miss nested branches like `feature/x`, and the query's own
    /// slashes stay literal, so "feature/t" keeps matching
    /// "feature/two-fix" across the component boundary. Wildmatch-
    /// special characters are backslash-escaped to match literally
    /// (branch names themselves can never contain them, but a query
    /// can). Nil — the blank query (no selector, list refs/heads/).
    public static func matchPattern(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var escaped = ""
        for char in trimmed {
            switch char {
            case "*", "?", "[", "]", "\\":
                escaped.append("\\")
                escaped.append(char)
            default:
                escaped.append(char)
            }
        }
        return "refs/heads/**/*" + escaped + "*"
    }
}
