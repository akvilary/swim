/// Pure position-resolution policy for a sectioned list that is
/// rebuilt in place — the git panel's status list. Given a position
/// captured before the rebuild and the freshly built sections, decides
/// where the position lands.
///
/// Policy: a position follows its entry while that entry stays in its
/// own section (rows shift as neighbours come and go); when the entry
/// moved to another section or disappeared, the position holds its
/// row, clamped to the section bounds — acting on consecutive entries
/// (staging several files in a row) does not chase the cursor across
/// sections. When the section itself is gone — or nothing was captured
/// because the list was empty before — the result is nil and the
/// caller picks the fallback: only the caller knows whether clamping
/// stale indices or collapsing onto another position fits its context.
///
/// The identity lookup is scoped to the position's own section on
/// purpose: the same identity may legitimately live in two sections at
/// once (a file with both staged and unstaged changes appears in
/// both), and a list-wide lookup would resolve to whichever section
/// comes first in display order — not to the section the position
/// actually addresses.
public enum SectionedListSelection {

    /// One rebuilt section: a stable key (sections are matched by key,
    /// not index — indices shift when a section empties out) plus the
    /// row identities in display order.
    public struct Section<Key: Equatable> {
        public let key: Key
        public let identities: [String]

        public init(key: Key, identities: [String]) {
            self.key = key
            self.identities = identities
        }
    }

    /// A resolved position: index into the rebuilt sections and a row
    /// within that section.
    public struct Position: Equatable {
        public let section: Int
        public let row: Int

        public init(section: Int, row: Int) {
            self.section = section
            self.row = row
        }
    }

    /// Resolves a captured position against the rebuilt sections:
    /// same-section identity follow, else same-row hold (clamped from
    /// both sides), else nil when the section key is gone, the section
    /// is empty, or nothing was captured.
    public static func resolve<Key: Equatable>(
        identity: String?,
        sectionKey: Key?,
        row: Int,
        sections: [Section<Key>]
    ) -> Position? {
        guard let sectionKey else { return nil }
        guard let index = sections.firstIndex(where: { $0.key == sectionKey }) else { return nil }
        let identities = sections[index].identities
        guard !identities.isEmpty else { return nil }
        if let identity, let found = identities.firstIndex(of: identity) {
            return Position(section: index, row: found)
        }
        return Position(section: index, row: max(0, min(row, identities.count - 1)))
    }
}
