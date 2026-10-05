import Testing
@testable import SwimCore

/// Contracts of `SectionedListSelection` — the git panel's
/// cursor-holding policy for rebuilt sectioned lists. Keys are the
/// panel's section kinds; identities are `file:<path>`-style strings.
@Suite struct StatusListSelectionTests {

    @Test func followsEntryWithinItsSection() {
        // Old unstaged [c, d, e], cursor row 2 on "e"; "c" vanished
        // above — the cursor must land on "e" at its new row.
        let sections = [SectionedListSelection.Section(key: "unstaged", identities: ["d", "e"])]
        let resolved = SectionedListSelection.resolve(
            identity: "e", sectionKey: "unstaged", row: 2, sections: sections)
        #expect(resolved == .init(section: 0, row: 1))
    }

    @Test func holdsRowWhenEntryMovedToAnotherSection() {
        // The user's scenario: staging "b" from unstaged [a, b, c] row 1
        // moves it into Staged — the cursor must hold row 1 in Unstaged,
        // landing on "c", so the next `s` stages "c".
        let sections = [
            SectionedListSelection.Section(key: "staged", identities: ["b"]),
            SectionedListSelection.Section(key: "unstaged", identities: ["a", "c"]),
        ]
        let resolved = SectionedListSelection.resolve(
            identity: "b", sectionKey: "unstaged", row: 1, sections: sections)
        #expect(resolved == .init(section: 1, row: 1))
    }

    @Test func holdsRowWhenEntryVanished() {
        // Discard: the entry is gone entirely, the section survives.
        let sections = [SectionedListSelection.Section(key: "unstaged", identities: ["a", "c"])]
        let resolved = SectionedListSelection.resolve(
            identity: "b", sectionKey: "unstaged", row: 1, sections: sections)
        #expect(resolved == .init(section: 0, row: 1))
    }

    @Test func clampsToLastRowWhenSectionShrank() {
        // Staged the last entry of the section: row 2 of 3, now 2 rows.
        let sections = [SectionedListSelection.Section(key: "untracked", identities: ["a", "b"])]
        let resolved = SectionedListSelection.resolve(
            identity: "c", sectionKey: "untracked", row: 2, sections: sections)
        #expect(resolved == .init(section: 0, row: 1))
    }

    @Test func resolvesByKeyWhenIndicesShift() {
        // Sections above emptied out: untracked was index 2, now 1 —
        // matching by key lands in the right section regardless.
        let sections = [
            SectionedListSelection.Section(key: "unstaged", identities: ["a"]),
            SectionedListSelection.Section(key: "untracked", identities: ["n", "o"]),
        ]
        let resolved = SectionedListSelection.resolve(
            identity: "o", sectionKey: "untracked", row: 1, sections: sections)
        #expect(resolved == .init(section: 1, row: 1))
    }

    @Test func duplicateIdentityResolvesInOwnSection() {
        // A file with both staged and unstaged changes lives in BOTH
        // sections under one identity; a position in Unstaged must
        // resolve to the unstaged copy, not to the staged one that
        // comes first in display order.
        let sections = [
            SectionedListSelection.Section(key: "staged", identities: ["mm"]),
            SectionedListSelection.Section(key: "unstaged", identities: ["mm", "b"]),
        ]
        let resolved = SectionedListSelection.resolve(
            identity: "mm", sectionKey: "unstaged", row: 0, sections: sections)
        #expect(resolved == .init(section: 1, row: 0))
    }

    @Test func returnsNilWhenSectionEmptiedOut() {
        // After a commit the staged section disappears — the caller
        // falls back to its own clamping.
        let sections = [SectionedListSelection.Section(key: "commits", identities: ["h1"])]
        let resolved = SectionedListSelection.resolve(
            identity: "a", sectionKey: "staged", row: 0, sections: sections)
        #expect(resolved == nil)
    }

    @Test func returnsNilWhenNothingCaptured() {
        // First-ever rebuild: the previous list was empty.
        let sections = [SectionedListSelection.Section(key: "staged", identities: ["a"])]
        let resolved = SectionedListSelection.resolve(
            identity: nil, sectionKey: Optional<String>.none, row: 0, sections: sections)
        #expect(resolved == nil)
    }

    @Test func emptySectionYieldsNil() {
        // Defensive: the panel filters empty sections out, but a caller
        // must not be able to ask for a row that cannot exist.
        let sections = [SectionedListSelection.Section(key: "staged", identities: [])]
        let resolved = SectionedListSelection.resolve(
            identity: nil, sectionKey: "staged", row: 0, sections: sections)
        #expect(resolved == nil)
    }

    @Test func negativeRowClampedToZero() {
        let sections = [SectionedListSelection.Section(key: "commits", identities: ["h1", "h2"])]
        let resolved = SectionedListSelection.resolve(
            identity: nil, sectionKey: "commits", row: -3, sections: sections)
        #expect(resolved == .init(section: 0, row: 0))
    }
}
