/// Pure parser behind the branch picker's `git for-each-ref` listing:
/// `--format=%(refname:short)%00%(committerdate:relative)%00%(HEAD)%00%(refname)`
/// — one ref per line, fields NUL-separated. The order is git's own
/// (`--sort=-committerdate`: newest last commit first, locals and
/// remotes mixed uniformly); swim never re-sorts. A fetched branch
/// lives in refs/remotes until it gains a local counterpart — the
/// picker shows it among the FILTERED results (the blank query lists
/// locals only) so `Enter`'s DWIM switch can create the tracking
/// branch, exactly like a manual `git switch <name>`. A remote row is
/// dropped when its LOCAL twin is also in the results — the local row
/// covers the same switch and `D`'s remote side. A remote's `HEAD`
/// pointer (`refs/remotes/<remote>/HEAD` — a symref to the
/// default branch, not a branch) is excluded. Also holds the picker's
/// one input-side rule of git ref names — the char-level forbidden
/// set (see `isForbiddenRefNameChar`). Dependency-free and
/// side-effect-free so it is unit-testable in isolation
/// (Tests/SwimCoreTests/BranchListTests.swift).
public enum BranchList {
    public struct Entry: Equatable {
        /// Short ref name (refname:short — "feature/x" or
        /// "origin/feature/x", not "refs/heads/feature/x").
        public let name: String
        /// Relative committerdate ("2 hours ago") — display-only.
        public let lastCommit: String
        /// True on the branch HEAD points at (`%(HEAD)` = "*").
        public let isCurrent: Bool
        /// True for remote-tracking entries (refs/remotes/...): shown
        /// only among filtered results, dimmed; `Enter` switches by the
        /// branch name without the remote prefix (git's DWIM creates
        /// the local tracking branch), `d`/`D` refuse.
        public let isRemote: Bool
    }

    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // The HEAD field is empty on non-current branches (git also
            // pads it with a space on some versions) — keep empty
            // subsequences so the field count stays honest.
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let refname = String(fields[3])
            if isRemoteHeadPointer(refname) { continue }
            entries.append(Entry(
                name: String(fields[0]),
                lastCommit: String(fields[1]),
                isCurrent: fields[2].trimmingCharacters(in: .whitespaces) == "*",
                isRemote: refname.hasPrefix("refs/remotes/")))
        }
        // A local branch makes its remote counterparts redundant in the
        // results: Enter on the local row is the same switch the remote
        // row would DWIM into, and `D` on the local row already covers
        // the remote side. A remote whose local twin is ABSENT stays —
        // on every remote it lives on (distinct refs, a real choice).
        // Order (git's committerdate) is preserved for the survivors.
        var localNames = Set<String>()
        for entry in entries where !entry.isRemote {
            localNames.insert(entry.name)
        }
        guard !localNames.isEmpty else { return entries }
        return entries.filter { entry in
            guard entry.isRemote, let slash = entry.name.firstIndex(of: "/") else {
                return true
            }
            return !localNames.contains(String(entry.name[entry.name.index(after: slash)...]))
        }
    }

    /// `refs/remotes/<remote>/HEAD` — the remote's symref to its
    /// default branch (a duplicate of a real entry, not a branch
    /// itself). Only the two-component form: a hypothetical
    /// `refs/remotes/origin/feature/HEAD` is a branch name like any
    /// other and stays.
    private static func isRemoteHeadPointer(_ refname: String) -> Bool {
        guard refname.hasPrefix("refs/remotes/") else { return false }
        let rest = refname.dropFirst("refs/remotes/".count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return rest[rest.index(after: slash)...] == "HEAD"
    }

    /// The for-each-ref selectors for a picker query: a contains-match
    /// on the ref name, paired with the command's `--ignore-case`.
    /// `**/` crosses path components — a lone `*` (WM_PATHNAME) would
    /// miss nested branches like `feature/x`, and the query's own
    /// slashes stay literal, so "feature/t" keeps matching
    /// "feature/two-fix" across the component boundary. Wildmatch-
    /// special characters are backslash-escaped to match literally
    /// (branch names themselves can never contain them, but a query
    /// can).
    ///
    /// The blank query lists LOCAL branches only — the unfiltered
    /// table is the working set; a query reaches into the remotes too
    /// (a fetched branch without a local counterpart is exactly what
    /// a search is for).
    public static func matchPatterns(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ["refs/heads/"] }
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
        return ["refs/heads/**/*" + escaped + "*", "refs/remotes/**/*" + escaped + "*"]
    }

    /// The character-level mirror of git's refname rules
    /// (git-check-ref-format): a ref name cannot have an ASCII control
    /// (a byte below 0x20, or DEL 0x7F), a space, or `~ ^ : ? * [ \`
    /// ANYWHERE. Checked per scalar, not per whole grapheme — git
    /// reads the name as bytes, and a combining mark stacked onto `~`
    /// still carries the `~` byte, which whole-Character equality
    /// would wave through. Deliberately the ONLY char-level rule:
    /// everything else git rejects is sequence-shaped (`..`, `@{`, a
    /// `.lock` tail, a leading dash, `//`) — invisible to a
    /// per-character gate and left to `git check-ref-format --branch`
    /// at Enter time, where git stays the single authority on the
    /// name as a whole.
    ///
    /// Consumers: the picker's create-phase input (typed and pasted
    /// characters refused by `Window.applyLineEdit`'s `allowed` gate,
    /// and the name seeded from the filter — see
    /// GitBranchesWindow). The merge phase does NOT gate: its input
    /// is `<ref> [args...]` — a space separates words and `HEAD~2` is
    /// a legal rev. Pinned against live git byte-by-byte in
    /// BranchNameInputTests (the mirror is verified, not trusted).
    public static func isForbiddenRefNameChar(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            if scalar.value < 0x20 || scalar.value == 0x7F { return true }
            switch scalar {
            case " ", "~", "^", ":", "?", "*", "[", "\\": return true
            default: return false
            }
        }
    }
}
