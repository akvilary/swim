import Testing
@testable import SwimCore

/// Smoke coverage for the markdown pass after its extraction from
/// SyntaxTokenizer: structure recognition per line and the incremental
/// viewport cache contract (a cached resume must equal a fresh scan).
struct MarkdownTokenizerTests {
    private func tokens(_ text: String, scrollY: Int = 0, height: Int = 20,
                        cache: inout MarkdownTokenizer.Cache) -> [SemanticToken] {
        MarkdownTokenizer.tokenizeVisible(buffer: PieceTable(text: text),
                                          scrollY: scrollY, height: height,
                                          cache: &cache)
    }

    @Test func headingFenceAndRule() {
        var cache = MarkdownTokenizer.Cache()
        let ts = tokens("# Title\n\n```\ncode\n```\n\ntext", cache: &cache)
        // Line 0: `#` marker + heading text.
        #expect(ts.contains { $0.line == 0 && $0.type == "keyword" })
        #expect(ts.contains { $0.line == 0 && $0.type == "type" })
        // Lines 2-4: fence open, block body, fence close — all string.
        for line in 2...4 {
            #expect(ts.contains { $0.line == line && $0.type == "string" })
        }
        // Line 6: plain text carries no tokens.
        #expect(!ts.contains { $0.line == 6 })
    }

    @Test func horizontalRuleIsComment() {
        var cache = MarkdownTokenizer.Cache()
        let ts = tokens("---", cache: &cache)
        #expect(ts.count == 1 && ts[0].type == "comment")
    }

    @Test func extensionRouting() {
        #expect(MarkdownTokenizer.isMarkdown("md"))
        #expect(MarkdownTokenizer.isMarkdown("markdown"))
        #expect(MarkdownTokenizer.isMarkdown("mdx"))
        #expect(!MarkdownTokenizer.isMarkdown("py"))
    }

    @Test func incrementalCacheMatchesFreshScan() {
        // Render lines 0-3 (opens and closes a fence), then scroll to 3
        // reusing the cache; the result must equal a cold scan from 0.
        let text = "# h\n```\ncode\n```\ntail\nmore"
        var warm = MarkdownTokenizer.Cache()
        _ = tokens(text, scrollY: 0, height: 4, cache: &warm)
        let incremental = tokens(text, scrollY: 3, height: 3, cache: &warm)
        var cold = MarkdownTokenizer.Cache()
        let reference = tokens(text, scrollY: 3, height: 3, cache: &cold)
        #expect(incremental == reference)
        // The window at 3..5 sees the closing fence as string, plain
        // lines after it untokenized.
        #expect(incremental.contains { $0.line == 3 && $0.type == "string" })
        #expect(!incremental.contains { $0.line == 4 })
    }
}
