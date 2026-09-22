/// Pure parser behind every consumer of `git status --porcelain -z`:
/// walks the NUL-separated `XY <path>` entries and collects the status
/// pair, the (repo-root-relative) path and — for rename/copy entries —
/// the original path that git appends as the next NUL field. Dependency-
/// free and side-effect-free so it is unit-testable in isolation
/// (Tests/SwimCoreTests/PorcelainTests.swift); both the git panel's
/// status list and the Application's decoration fetch go through it, so
/// the subtle orig-field consumption lives exactly once.
public enum Porcelain {
    public struct Entry: Equatable {
        /// Index-tree status (first column) and worktree status (second).
        public let x: Character
        public let y: Character
        /// Repo-root-relative path, raw (unquoted, unescaped — `-z`).
        public let path: String
        /// Original path of a staged rename/copy (`R`/`C` in X), nil
        /// otherwise. Consume-only for other shapes: the field exists
        /// so the NEXT entry is not misparsed, the value is kept for
        /// the panel's rename discard/unstage.
        public let origPath: String?

        /// Display class of the entry (see `GitChangeClass.classify`).
        public var changeClass: GitChangeClass? {
            GitChangeClass.classify(x: x, y: y)
        }
    }

    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            // "XY <path>" — anything shorter is not an entry.
            guard field.count >= 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            var origPath: String? = nil
            if x == "R" || x == "C" || y == "R" {
                origPath = fields.next().map(String.init)
            }
            entries.append(Entry(x: x, y: y, path: path, origPath: origPath))
        }
        return entries
    }
}

/// The three user-facing classes of a changed file, used for the git
/// coloring (explorer names, editor gutter): `added` — untracked (`??`)
/// only, green; `staged` — every change sits in the index (a staged add
/// `A` included — it is staged, the same color as the panel's A);
/// `unstaged` — at least one working-tree change. Precedence: ANY
/// worktree column change outranks the index (orange) — the unstaged
/// edit is the state the user would save next. Nil for shapes with
/// nothing to color.
public enum GitChangeClass: Equatable {
    case added
    case staged
    case unstaged

    public static func classify(x: Character, y: Character) -> GitChangeClass? {
        if x == "?" && y == "?" { return .added }
        if y != " " && y != "?" { return .unstaged }
        if x != " " { return .staged }
        return nil
    }
}
