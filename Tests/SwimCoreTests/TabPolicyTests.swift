import Testing
import SwimCore

/// TabPolicy.expandTabs — one tab = one indent step of spaces, the
/// width the auto-indenter produces. Tab-free text (the common paste)
/// returns identical, untouched.
@Suite struct TabPolicyTests {

    @Test func noTabsReturnsSameInstance() {
        let text = "    foo {\n        bar\n    }"
        #expect(TabPolicy.expandTabs(text, indent: 2) == text)
        #expect(TabPolicy.expandTabs("", indent: 4) == "")
    }

    @Test func leadingTabsBecomeIndentSteps() {
        #expect(TabPolicy.expandTabs("\tlet x = 1", indent: 2) == "  let x = 1")
        #expect(TabPolicy.expandTabs("\tdef f():", indent: 4) == "    def f():")
        #expect(TabPolicy.expandTabs("\t\tdeep", indent: 2) == "    deep")
    }

    @Test func midLineTabsAlsoExpand() {
        #expect(TabPolicy.expandTabs("a\tb", indent: 4) == "a    b")
    }

    @Test func mixedTabsAndSpaces() {
        #expect(TabPolicy.expandTabs("  \tfoo", indent: 2) == "    foo")
    }

    @Test func multilineEveryLineNormalized() {
        #expect(TabPolicy.expandTabs("\tfoo\n\t\tbar\nbaz", indent: 2) == "  foo\n    bar\nbaz")
    }

    @Test func zeroIndentClampsToOneSpace() {
        #expect(TabPolicy.expandTabs("\tx", indent: 0) == " x")
    }
}
