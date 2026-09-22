import Foundation
import Testing
@testable import SwimCore

/// Coverage for the builtin tokenizer's Python string handling and the
/// LSP merge. The f-string fix had two halves: string prefixes (f/r/b/u)
/// must open the string token, and builtin string tokens must survive
/// LSP tokens emitted for interpolation expressions — pyright leaves
/// string coloring to syntax highlighting but still tokenizes `{expr}`
/// innards, which used to evict the whole string span.
struct SyntaxTokenizerTests {
    private func pyTokens(_ s: String, line: Int = 0,
                          initial: SyntaxTokenizer.MultilineStringState = .none)
        -> (tokens: [SemanticToken], endState: SyntaxTokenizer.MultilineStringState) {
        SyntaxTokenizer.tokenize(chars: Array(s), lineNum: line,
                                 keywords: SyntaxTokenizer.pythonKeywords,
                                 syntax: SyntaxTokenizer.syntax(for: "py"),
                                 initialState: initial,
                                 literals: SyntaxTokenizer.pythonLiterals)
    }

    private func swiftTokens(_ s: String) -> [SemanticToken] {
        SyntaxTokenizer.tokenize(chars: Array(s), lineNum: 0,
                                 keywords: SyntaxTokenizer.swiftKeywords,
                                 syntax: SyntaxTokenizer.syntax(for: "swift"),
                                 literals: SyntaxTokenizer.swiftLiterals).tokens
    }

    private func has(_ tokens: [SemanticToken], _ start: Int, _ length: Int, _ type: String) -> Bool {
        tokens.contains { $0.startChar == start && $0.length == length && $0.type == type }
    }

    // MARK: - string prefixes

    @Test func fStringIsOneStringTokenIncludingPrefix() {
        let ts = pyTokens(#"x = f"hello {name}!""#).tokens
        #expect(has(ts, 4, 16, "string")) // f"hello {name}!"
    }

    @Test func prefixCombinationsAndQuoteKinds() {
        #expect(has(pyTokens(#"y = f'mid {a} tail'"#).tokens, 4, 15, "string"))
        #expect(has(pyTokens(#"z = rb'raw'"#).tokens, 4, 7, "string"))
        #expect(has(pyTokens(#"w = F"upper""#).tokens, 4, 8, "string"))
    }

    @Test func prefixDirectlyAbuttingTripleQuote() {
        let ts = pyTokens(#"q = f"""triple {x}""""#).tokens
        #expect(has(ts, 4, 17, "string")) // f"""triple {x}"""
    }

    @Test func spacedPrefixStaysIdentifier() {
        // `f "x"` (with a space) is `f` applied near a string, not an
        // f-string — the prefix must remain a plain identifier.
        let ts = pyTokens(#"v = f "spaced""#).tokens
        #expect(has(ts, 4, 1, "variable"))
        #expect(has(ts, 6, 8, "string"))
    }

    @Test func plainIdentifiersWithPrefixLettersUnaffected() {
        // `fmt(x)`: f-m-t — only `f`/`r`/`b`/`u` letters; `m` stops the
        // prefix scan before the `(`, so `fmt` is a function call.
        let ts = pyTokens("fmt(x)").tokens
        #expect(ts.first?.type == "function")
        // `foo_f"x"` — underscore is not a prefix letter; the whole word
        // stays one identifier and the string opens separately.
        let ts2 = pyTokens(#"a = foo_f"x""#).tokens
        #expect(ts2.contains { $0.type == "variable" && $0.length == 5 })
    }

    @Test func escapesHonoredEvenForRawPrefixes() {
        // CPython: even in raw literals a backslash escapes the quote for
        // termination (a raw string cannot end in a backslash), so
        // `r"a\"` is unterminated and runs to end of line.
        let ts = pyTokens(#"p = r"a\""#).tokens
        #expect(ts.contains { $0.type == "string" && $0.startChar == 4 && $0.length == 5 })
        // `r"\""` is a complete string containing \".
        let ts2 = pyTokens(#"p = r"\"""#).tokens
        #expect(has(ts2, 4, 5, "string"))
    }

    @Test func unclosedPrefixedTripleOpensMultilineState() {
        let (ts, state) = pyTokens(#"s = f"""start"#)
        #expect(state == .active(ruleIndex: 0))
        #expect(ts.last?.type == "string")
        // Continuation line closes the string from column 0.
        let (ts2, state2) = pyTokens(#"end""""#, line: 1, initial: state)
        #expect(state2 == .none)
        #expect(ts2.first?.type == "string")
    }

    @Test func commentWinsOverPrefixString() {
        let ts = pyTokens(#"# f"not a string""#).tokens
        #expect(ts.count == 1 && ts[0].type == "comment")
    }

    @Test func nonPythonLanguagesSkipPrefixLogic() {
        // Swift: `f` before a spaced string is a plain identifier; the
        // stringPrefixes profile flag is python-only.
        let ts = swiftTokens(#"let f = "x""#)
        #expect(ts.contains { $0.type == "variable" && $0.startChar == 4 })
    }

    // MARK: - LSP merge

    private func tok(_ start: Int, _ length: Int, _ type: String) -> SemanticToken {
        SemanticToken(line: 0, startChar: start, length: length, type: type, modifiers: 0)
    }

    @Test func mergeStringSwallowsNestedLSPTokens() {
        // x = f"hello {name}!"  — pyright emits: x(0), name(14)
        let builtin = pyTokens(#"x = f"hello {name}!""#).tokens
        let lsp = [tok(0, 1, "variable"), tok(14, 4, "variable")]
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)
        // The string span survives…
        #expect(merged.contains { $0.type == "string" && $0.startChar == 4 })
        // …the nested interpolation token is swallowed…
        #expect(!merged.contains { $0.startChar == 14 })
        // …and the token outside the string is kept.
        #expect(merged.contains { $0.type == "variable" && $0.startChar == 0 })
        // Output is sorted and free of overlaps.
        let sorted = merged.sorted { $0.startChar < $1.startChar }
        #expect(merged == sorted)
    }

    @Test func mergePartialOverlapStillEvictsBuiltin() {
        // An LSP token crossing the string edge is not nested — the old
        // eviction rule applies (LSP is authoritative where it speaks).
        // `x = "plain"`: string spans [4, 11); tok(6, 8) ends at 14,
        // past the closing quote.
        let builtin = pyTokens(#"x = "plain""#).tokens
        let lsp = [tok(6, 8, "macro")]
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)
        #expect(!merged.contains { $0.type == "string" && $0.startChar == 4 })
        #expect(merged.contains { $0.startChar == 6 && $0.length == 8 })
    }

    @Test func mergeEvictedStringDoesNotSwallowNestedTokens() {
        // A string evicted by a partially overlapping LSP token must not
        // take nested LSP tokens with it — that would leave both spans
        // uncovered (a hole). `x = "plain"`: string [4, 11); l1 [8, 13)
        // crosses the closing quote and evicts the string; l2 [5, 6) is
        // nested but must survive.
        let builtin = pyTokens(#"x = "plain""#).tokens
        let l1 = tok(8, 5, "macro")
        let l2 = tok(5, 1, "variable")
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: [l1, l2])
        #expect(!merged.contains { $0.type == "string" && $0.startChar == 4 })
        #expect(merged.contains { $0.startChar == 8 && $0.length == 5 })
        #expect(merged.contains { $0.startChar == 5 && $0.length == 1 })
    }

    @Test func mergeFuzzInvariantsHold() {
        // Deterministic LCG — a failing seed reproduces exactly.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        // Builds a disjoint, ascending span set across a 40-col line.
        func randomSpans() -> [SemanticToken] {
            let types = ["string", "variable", "keyword", "number", "operator"]
            var spans = [SemanticToken]()
            var col = Int(next() % 5)
            while col < 40 {
                let len = Int(next() % 6) + 1
                spans.append(tok(col, len, types[Int(next() % 5)]))
                col += len + Int(next() % 3)
            }
            return spans
        }

        for _ in 0..<200 {
            let builtin = randomSpans()
            let lsp = randomSpans()
            let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)

            // Output is sorted, pairwise disjoint and invents no tokens.
            if merged.count > 1 {
                for k in 1..<merged.count {
                    #expect(merged[k - 1].startChar <= merged[k].startChar)
                    #expect(merged[k - 1].startChar + merged[k - 1].length <= merged[k].startChar)
                }
            }
            #expect(merged.allSatisfy { builtin.contains($0) || lsp.contains($0) })
        }
    }

    @Test func mergeNoLSPKeepsBuiltinVerbatim() {
        let builtin = pyTokens(#"x = f"a""#).tokens
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: [])
        #expect(merged == builtin)
    }
}
