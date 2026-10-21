import Foundation

/// Pure parser behind the git log window's `git log --format=%h|%s`
/// listing: one commit per line, the short hash and the subject
/// separated by the FIRST `|` (`maxSplits: 1` — a subject containing
/// pipes keeps them; `%h` is hex and never contains one). The order is
/// git's own (default reverse-chronological); swim never re-sorts.
/// Malformed lines (fewer than two fields — a truncated tail of a
/// still-running command) are skipped, not fatal. `%s` is the subject
/// — the first line of the message by definition, so line splitting is
/// safe. Dependency-free and side-effect-free so it is unit-testable
/// in isolation (Tests/SwimCoreTests/CommitLogTests.swift).
public enum CommitLog {
    public struct Entry: Equatable, Sendable {
        /// Short hash exactly as git printed it (`%h`). Git scales the
        /// abbreviation width with repository size, so the string is
        /// kept verbatim — rows display it and `y` copies the same
        /// unambiguous token (a hard `prefix(7)` could show two rows
        /// alike and copy an ambiguous prefix on huge repositories).
        public let hash: String
        /// Commit subject (`%s`) — may be empty (an empty-message
        /// commit renders as a bare hash).
        public let subject: String

        public init(hash: String, subject: String) {
            self.hash = hash
            self.subject = subject
        }
    }

    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            entries.append(Entry(hash: String(fields[0]), subject: String(fields[1])))
        }
        return entries
    }
}
