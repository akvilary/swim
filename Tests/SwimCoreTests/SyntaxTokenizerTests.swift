import Foundation
import Testing
@testable import SwimCore

/// Coverage for the builtin tokenizer's string handling and the LSP
/// merge. Interpolation is ONE engine gated by per-language data
/// (InterpolationRule): python f-strings, swift \(…), C# $"…",
/// js templates, ruby/dart/shell ${…}/#{…} — the tests below pin the
/// emission contract: text chunks → string, delimiters → interpolation
/// (the string hue dimmed 40% — Theme derives it from the string
/// color), field expression → ordinary code tokens, format spec →
/// string.
struct SyntaxTokenizerTests {
    /// The one fixture driver — every language helper below is a thin
    /// wrapper over it (keywords/syntax/literals resolved by extension
    /// in one place).
    private func tokens(_ s: String, ext: String, line: Int = 0,
                        initial: SyntaxTokenizer.MultilineStringState = .none)
        -> (tokens: [SemanticToken], endState: SyntaxTokenizer.MultilineStringState) {
        SyntaxTokenizer.tokenize(chars: Array(s), lineNum: line,
                                 keywords: SyntaxTokenizer.keywords(for: ext),
                                 syntax: SyntaxTokenizer.syntax(for: ext),
                                 initialState: initial,
                                 literals: SyntaxTokenizer.valueLiterals(for: ext))
    }

    private func pyTokens(_ s: String, line: Int = 0,
                          initial: SyntaxTokenizer.MultilineStringState = .none)
        -> (tokens: [SemanticToken], endState: SyntaxTokenizer.MultilineStringState) {
        tokens(s, ext: "py", line: line, initial: initial)
    }

    private func swiftTokens(_ s: String, line: Int = 0,
                             initial: SyntaxTokenizer.MultilineStringState = .none)
        -> (tokens: [SemanticToken], endState: SyntaxTokenizer.MultilineStringState) {
        tokens(s, ext: "swift", line: line, initial: initial)
    }

    private func csTokens(_ s: String) -> [SemanticToken] {
        tokens(s, ext: "cs").tokens
    }

    private func jsTokens(_ s: String, line: Int = 0,
                          initial: SyntaxTokenizer.MultilineStringState = .none)
        -> (tokens: [SemanticToken], endState: SyntaxTokenizer.MultilineStringState) {
        tokens(s, ext: "js", line: line, initial: initial)
    }

    private func rbTokens(_ s: String) -> [SemanticToken] {
        tokens(s, ext: "rb").tokens
    }

    private func dartTokens(_ s: String) -> [SemanticToken] {
        tokens(s, ext: "dart").tokens
    }

    private func shTokens(_ s: String) -> [SemanticToken] {
        tokens(s, ext: "sh").tokens
    }

    private func rustTokens(_ s: String) -> [SemanticToken] {
        tokens(s, ext: "rs").tokens
    }

    private func has(_ tokens: [SemanticToken], _ start: Int, _ length: Int, _ type: String) -> Bool {
        tokens.contains { $0.startChar == start && $0.length == length && $0.type == type }
    }

    // MARK: - string prefixes

    @Test func fStringSegmentsIntoChunksCodeAndDelimiters() {
        // x = f"hello {name}!"
        //    └string┘└p┘└var┘└p┘└str┘
        let ts = pyTokens(#"x = f"hello {name}!""#).tokens
        #expect(has(ts, 4, 8, "string"))          // f"hello 
        #expect(has(ts, 12, 1, "interpolation"))    // {
        #expect(has(ts, 13, 4, "variable"))       // name
        #expect(has(ts, 17, 1, "interpolation"))    // }
        #expect(has(ts, 18, 2, "string"))         // !"
    }

    @Test func prefixCombinationsAndQuoteKinds() {
        let ts = pyTokens(#"y = f'mid {a} tail'"#).tokens
        #expect(has(ts, 4, 6, "string"))
        #expect(has(ts, 10, 1, "interpolation"))
        #expect(has(ts, 11, 1, "variable"))
        #expect(has(ts, 13, 6, "string"))
        // No f in the prefix — one plain string token, no fields.
        #expect(has(pyTokens(#"z = rb'raw'"#).tokens, 4, 7, "string"))
        #expect(!pyTokens(#"z = rb'raw'"#).tokens.contains { $0.type == "interpolation" })
        #expect(has(pyTokens(#"w = F"upper""#).tokens, 4, 8, "string"))
    }

    @Test func prefixDirectlyAbuttingTripleQuote() {
        let ts = pyTokens(#"q = f"""triple {x}""""#).tokens
        #expect(has(ts, 4, 11, "string"))         // f"""triple 
        #expect(has(ts, 15, 1, "interpolation"))
        #expect(has(ts, 16, 1, "variable"))
        #expect(has(ts, 18, 3, "string"))         // """
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
        // `r"a\"` is unterminated and runs to end of line — [4,9),
        // exactly to the line's end (the escape-skip lands on it; a
        // backslash as the VERY last char is clamped by the fuzz-pinned
        // never-leave-your-line rule).
        let ts = pyTokens(#"p = r"a\""#).tokens
        #expect(ts.contains { $0.type == "string" && $0.startChar == 4 && $0.length == 5 })
        // `r"\""` is a complete string containing \".
        let ts2 = pyTokens(#"p = r"\"""#).tokens
        #expect(has(ts2, 4, 5, "string"))
    }

    @Test func unclosedPrefixedTripleOpensMultilineState() {
        let (ts, state) = pyTokens(#"s = f"""start"#)
        #expect(state == .active(ruleIndex: 0, interpolating: true))
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
        // prefix vocabulary is per language.
        let ts = swiftTokens(#"let f = "x""#).tokens
        #expect(ts.contains { $0.type == "variable" && $0.startChar == 4 })
    }

    // MARK: - python interpolation

    @Test func doubledBracesAreLiteralString() {
        let ts = pyTokens(#"w = f"{{x}}""#).tokens
        #expect(has(ts, 4, 8, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
        #expect(!ts.contains { $0.type == "variable" && $0.startChar == 8 })
    }

    @Test func formatSpecStaysString() {
        // t = f"{x:>10}"
        let ts = pyTokens(#"t = f"{x:>10}""#).tokens
        #expect(has(ts, 4, 2, "string"))          // f"
        #expect(has(ts, 6, 1, "interpolation"))
        #expect(has(ts, 7, 1, "variable"))        // x
        #expect(has(ts, 8, 4, "string"))          // :>10
        #expect(has(ts, 12, 1, "interpolation"))
        #expect(has(ts, 13, 1, "string"))
    }

    @Test func sliceColonIsNotSpecSeparator() {
        // The ':' inside […] is at bracket depth — code, not spec.
        let ts = pyTokens(#"s = f"{a[1:2]}""#).tokens
        #expect(has(ts, 6, 1, "interpolation"))
        #expect(has(ts, 7, 1, "variable"))        // a
        #expect(has(ts, 9, 1, "number"))          // 1
        #expect(has(ts, 10, 1, "operator"))       // :
        #expect(has(ts, 11, 1, "number"))         // 2
        #expect(has(ts, 13, 1, "interpolation"))
        #expect(!ts.contains { $0.type == "string" && $0.startChar == 10 })
    }

    @Test func dictColonIsNotSpecSeparator() {
        // d = f"{ {'k': 1}[k] }"
        let ts = pyTokens(#"d = f"{ {'k': 1}[k] }""#).tokens
        #expect(has(ts, 6, 1, "interpolation"))
        #expect(has(ts, 9, 3, "string"))          // 'k'
        #expect(has(ts, 12, 1, "operator"))       // : (dict, depth > 0)
        #expect(has(ts, 14, 1, "number"))         // 1
        #expect(has(ts, 17, 1, "variable"))       // k
        #expect(has(ts, 20, 1, "interpolation"))
        #expect(!ts.contains { $0.type == "string" && $0.startChar == 12 })
    }

    @Test func braceInsideQuotedExpressionDoesNotCloseField() {
        // r2 = f"{s.replace('a', '}')}" — the '}' inside '}'} is nested
        // in a string literal; the field closes at the LAST bracket.
        let ts = pyTokens(#"r2 = f"{s.replace('a', '}')}""#).tokens
        #expect(has(ts, 7, 1, "interpolation"))
        #expect(has(ts, 8, 1, "variable"))        // s
        #expect(has(ts, 10, 7, "function"))       // replace
        #expect(has(ts, 18, 3, "string"))         // 'a'
        #expect(has(ts, 23, 3, "string"))         // '}'
        #expect(has(ts, 27, 1, "interpolation"))    // the real closer
        #expect(has(ts, 28, 1, "string"))
    }

    @Test func nestedFStringInterpolates() {
        // n = f"{f'{x}'}" — the recursive field scan tokenizes the
        // inner literal as a full f-string.
        let ts = pyTokens(#"n = f"{f'{x}'}""#).tokens
        #expect(has(ts, 6, 1, "interpolation"))
        #expect(has(ts, 7, 2, "string"))          // f'
        #expect(has(ts, 9, 1, "interpolation"))
        #expect(has(ts, 10, 1, "variable"))       // x
        #expect(has(ts, 12, 1, "string"))
        #expect(has(ts, 13, 1, "interpolation"))
    }

    @Test func backslashDoesNotSwallowPythonOpener() {
        // CPython: f"\{x}" keeps the backslash as text and still opens
        // the field.
        let ts = pyTokens(#"b = f"\{x}""#).tokens
        #expect(has(ts, 4, 3, "string"))          // f"\
        #expect(has(ts, 7, 1, "interpolation"))
        #expect(has(ts, 8, 1, "variable"))
        #expect(has(ts, 9, 1, "interpolation"))
        #expect(has(ts, 10, 1, "string"))
    }

    @Test func unclosedOpenerDegradesToString() {
        // u = f"{oops" — no matching '}' before the quote: INV1 — the
        // opener becomes text, the string still terminates at the quote.
        let ts = pyTokens(#"u = f"{oops""#).tokens
        #expect(has(ts, 4, 8, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    @Test func rfCombinationInterpolates() {
        let ts = pyTokens(#"q = rf"{x}""#).tokens
        #expect(has(ts, 4, 3, "string"))
        #expect(has(ts, 7, 1, "interpolation"))
        #expect(has(ts, 8, 1, "variable"))
    }

    @Test func plainStringsAndDocstringsStayWhole() {
        // No f prefix — {x} is plain text.
        #expect(has(pyTokens(#"x = "plain {y}""#).tokens, 4, 11, "string"))
        #expect(has(pyTokens(#"x = r"{y}""#).tokens, 4, 6, "string"))
        let ts = pyTokens(#"q = """{x}""""#).tokens
        #expect(has(ts, 4, 9, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    @Test func multilineFStringInterpolatesAcrossLadder() {
        // Line 0 opens and interpolates; the ladder carries the
        // interpolating flag; line 1 continues and closes.
        let (ts0, state0) = pyTokens(#"s = f"""a {x}"#)
        #expect(state0 == .active(ruleIndex: 0, interpolating: true))
        #expect(has(ts0, 4, 6, "string"))         // f"""a 
        #expect(has(ts0, 10, 1, "interpolation"))
        #expect(has(ts0, 11, 1, "variable"))
        let (ts1, state1) = pyTokens(#"b {y} c""""#, line: 1, initial: state0)
        #expect(state1 == .none)
        #expect(has(ts1, 0, 2, "string"))         // b␣
        #expect(has(ts1, 2, 1, "interpolation"))
        #expect(has(ts1, 3, 1, "variable"))
        #expect(has(ts1, 4, 1, "interpolation"))
        #expect(has(ts1, 5, 5, "string"))         // ␣c"""
    }

    // MARK: - swift interpolation

    @Test func swiftInterpolationSegments() {
        // let s = "hello \(name)"
        let ts = swiftTokens(#"let s = "hello \(name)""#).tokens
        #expect(has(ts, 8, 7, "string"))          // "hello \
        #expect(has(ts, 15, 2, "interpolation"))    // \(
        #expect(has(ts, 17, 4, "variable"))       // name
        #expect(has(ts, 21, 1, "interpolation"))    // )
        #expect(has(ts, 22, 1, "string"))
    }

    @Test func swiftNestedQuotesInsideFieldDoNotTerminateString() {
        // The pre-interpolation bug: "\(d["k"])" used to end the string
        // at the nested quote. The field matcher skips quoted regions.
        let ts = swiftTokens(#"let v = "\(d["k"])""#).tokens
        #expect(has(ts, 8, 1, "string"))          // "
        #expect(has(ts, 9, 2, "interpolation"))     // \(
        #expect(has(ts, 11, 1, "variable"))       // d
        #expect(has(ts, 13, 3, "string"))         // "k"
        #expect(has(ts, 17, 1, "interpolation"))    // )
        #expect(has(ts, 18, 1, "string"))
    }

    @Test func swiftTripleOpensInterpolatingLadder() {
        let (ts, state) = swiftTokens(#"let s = """\(x)"#)
        #expect(state == .active(ruleIndex: 0, interpolating: true))
        #expect(has(ts, 8, 3, "string"))          // """
        #expect(has(ts, 11, 2, "interpolation"))    // \(
        #expect(has(ts, 13, 1, "variable"))       // x
        // A field may not straddle lines (documented limitation): the
        // ')' on the continuation line is string text, the string still
        // closes at """ — per-line degradation, ladder intact.
        let (ts2, state2) = swiftTokens(#"y) tail""""#, line: 1, initial: state)
        #expect(state2 == .none)
        #expect(ts2.first?.type == "string")
    }

    // MARK: - C# interpolation

    @Test func csharpInterpolatedString() {
        // var s = $"Hello {name}"
        let ts = csTokens(#"var s = $"Hello {name}""#)
        #expect(has(ts, 8, 8, "string"))          // $"Hello 
        #expect(has(ts, 16, 1, "interpolation"))
        #expect(has(ts, 17, 4, "variable"))
        #expect(has(ts, 21, 1, "interpolation"))
        #expect(has(ts, 22, 1, "string"))
    }

    @Test func csharpAlignmentAndSpecStayString() {
        // var t = $"{x,10:N2}" — the depth-zero ',' (alignment) and ':'
        // (format) both open the spec.
        let ts = csTokens(#"var t = $"{x,10:N2}""#)
        #expect(has(ts, 8, 2, "string"))
        #expect(has(ts, 10, 1, "interpolation"))
        #expect(has(ts, 11, 1, "variable"))       // x
        #expect(has(ts, 12, 6, "string"))         // ,10:N2
        #expect(has(ts, 18, 1, "interpolation"))
        #expect(has(ts, 19, 1, "string"))
    }

    @Test func csharpVerbatimInterpolatedPath() {
        // $@"C:\{x}" — in verbatim strings the backslash is literal, so
        // the field after it still opens (openAfterBackslash).
        let ts = csTokens(#"var s = $@"C:\{x}""#)
        #expect(has(ts, 8, 6, "string"))          // $@"C:\
        #expect(has(ts, 14, 1, "interpolation"))
        #expect(has(ts, 15, 1, "variable"))       // x
        #expect(has(ts, 16, 1, "interpolation"))
        #expect(has(ts, 17, 1, "string"))
    }

    @Test func csharpRawInterpolatedIsDeferred() {
        // $"""raw {x}""" — single-brace semantics; one plain string.
        let ts = csTokens(#"var r = $"""raw {x}""""#)
        #expect(has(ts, 8, 14, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    @Test func csharpVerbatimPrefixDoesNotInterpolate() {
        let ts = csTokens(#"var p = @"C:\x""#)
        #expect(has(ts, 8, 7, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    // MARK: - js template literals

    @Test func jsTemplateLiteralSegments() {
        // Backticks are strings (the pre-existing gap: templates were
        // not colored at all) and ${…} interpolates.
        let ts = jsTokens("let s = `hello ${name}`").tokens
        #expect(has(ts, 8, 7, "string"))          // `hello␣
        #expect(has(ts, 15, 2, "interpolation"))    // ${
        #expect(has(ts, 17, 4, "variable"))
        #expect(has(ts, 21, 1, "interpolation"))
        #expect(has(ts, 22, 1, "string"))
    }

    @Test func jsEscapedDollarStaysLiteral() {
        // `\${` escapes the interpolation — the escape-skip eats the
        // backslash-dollar pair; the lone '{' is not a trigger.
        let ts = jsTokens(#"let e = `a \${x} b`"#).tokens
        #expect(has(ts, 8, 11, "string"))
        #expect(!ts.contains { $0.type == "variable" && $0.startChar >= 8 })
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    @Test func jsDoubleQuotedStringsDoNotInterpolate() {
        let ts = jsTokens(#"let s = "a ${x} b""#).tokens
        #expect(has(ts, 8, 10, "string"))
        #expect(!ts.contains { $0.type == "variable" && $0.startChar == 13 })
    }

    @Test func jsTemplateLadderInterpolatesOnContinuation() {
        let (ts, state) = jsTokens("const s = `start")
        #expect(state == .active(ruleIndex: 0, interpolating: true))
        #expect(ts.last?.type == "string")
        let (ts2, state2) = jsTokens("${x} tail`", line: 1, initial: state)
        #expect(state2 == .none)
        #expect(has(ts2, 0, 2, "interpolation"))    // ${
        #expect(has(ts2, 2, 1, "variable"))
        #expect(has(ts2, 3, 1, "interpolation"))
        #expect(has(ts2, 4, 6, "string"))         // ␣tail`
    }

    // MARK: - ruby / dart / shell

    @Test func rubyDoubleQuotesInterpolate() {
        let ts = rbTokens(#"puts "hi #{name}""#)
        #expect(has(ts, 5, 4, "string"))          // "hi␣
        #expect(has(ts, 9, 2, "interpolation"))     // #{
        #expect(has(ts, 11, 4, "variable"))
        #expect(has(ts, 15, 1, "interpolation"))
        #expect(has(ts, 16, 1, "string"))
        // Single quotes are literal in ruby.
        let ts2 = rbTokens(#"puts 'no #{x}'"#)
        #expect(has(ts2, 5, 9, "string"))
        #expect(!ts2.contains { $0.type == "variable" && $0.startChar >= 5 })
    }

    @Test func dartInterpolationAndRawPrefix() {
        let ts = dartTokens(#"print('${greeting}')"#)
        #expect(has(ts, 6, 1, "string"))          // '
        #expect(has(ts, 7, 2, "interpolation"))     // ${
        #expect(has(ts, 9, 8, "variable"))        // greeting
        #expect(has(ts, 17, 1, "interpolation"))
        #expect(has(ts, 18, 1, "string"))
        // Raw r'…' does not interpolate (and the prefix joins the token).
        let ts2 = dartTokens(#"print(r'${x}')"#)
        #expect(has(ts2, 6, 7, "string"))
        #expect(!ts2.contains { $0.type == "variable" })
    }

    @Test func shellDoubleQuotesInterpolate() {
        let ts = shTokens(#"echo "hi ${name}""#)
        #expect(has(ts, 5, 4, "string"))          // "hi␣
        #expect(has(ts, 9, 2, "interpolation"))     // ${
        #expect(has(ts, 11, 4, "variable"))
        #expect(has(ts, 15, 1, "interpolation"))
        #expect(has(ts, 16, 1, "string"))
        // Single quotes are literal in shell.
        let ts2 = shTokens(#"echo 'lit ${x}'"#)
        #expect(has(ts2, 5, 10, "string"))
    }

    // MARK: - languages without interpolation are byte-identical (INV3)

    @Test func rustStringsStayWhole() {
        let ts = rustTokens(#"let s = "raw {x}";"#)
        #expect(has(ts, 8, 9, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
        #expect(!ts.contains { $0.type == "variable" && $0.startChar == 14 })
    }

    /// Adversarial lines across every interpolating language: whatever
    /// the scanner does, its output must stay a well-formed token
    /// stream — sorted by startChar, pairwise disjoint, positive
    /// lengths, spans inside the line — and the walk must terminate
    /// (the ladder state is always one of the two cases).
    @Test func interpolationFuzzKeepsInvariants() {
        var seed: UInt64 = 0xD1B54A32D192ED03
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        // A hostile alphabet: quotes, braces, backslashes, prefixes,
        // interpolation openers, spec separators, expression fragments.
        let fragments = ["f", "r", "$", "@", "\"", "'", "`", "{", "}", "${",
                         "#{", "\\(", "\\{", "\\", "{{", "}}", ":", ",", "x",
                         "name", "(a)", "[1:2]", "'}'", "\"k\"", "#", " ",
                         "\"\"\"", "'''", ">10", "=", "!"]
        let exts = ["py", "swift", "cs", "js", "rb", "dart", "sh"]

        for _ in 0..<400 {
            let ext = exts[Int(next() % UInt64(exts.count))]
            let count = 3 + Int(next() % 25)
            let line = (0..<count).map { _ in fragments[Int(next() % UInt64(fragments.count))] }.joined()
            let chars = Array(line)
            let result = SyntaxTokenizer.tokenize(
                chars: chars, lineNum: 0,
                keywords: SyntaxTokenizer.keywords(for: ext),
                syntax: SyntaxTokenizer.syntax(for: ext),
                initialState: .none,
                literals: SyntaxTokenizer.valueLiterals(for: ext))

            var prevEnd = 0
            for t in result.tokens {
                #expect(t.length > 0)
                #expect(t.startChar >= prevEnd)
                #expect(t.startChar + t.length <= chars.count)
                prevEnd = t.startChar + t.length
            }
            // The endState is either none or a valid ladder entry; and a
            // none/active decision must not depend on anything but the
            // line (determinism): re-run and compare.
            let again = SyntaxTokenizer.tokenize(
                chars: chars, lineNum: 0,
                keywords: SyntaxTokenizer.keywords(for: ext),
                syntax: SyntaxTokenizer.syntax(for: ext),
                initialState: .none,
                literals: SyntaxTokenizer.valueLiterals(for: ext))
            #expect(result.tokens == again.tokens)
            #expect(result.endState == again.endState)
        }
    }

    // MARK: - LSP merge

    private func tok(_ start: Int, _ length: Int, _ type: String) -> SemanticToken {
        SemanticToken(line: 0, startChar: start, length: length, type: type, modifiers: 0)
    }

    @Test func mergePlainStringSwallowsNestedLSPTokens() {
        // x = "plain" — string [4,11); a token nested in it is absorbed.
        let builtin = pyTokens(#"x = "plain""#).tokens
        let lsp = [tok(6, 3, "macro")]
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)
        #expect(merged.contains { $0.type == "string" && $0.startChar == 4 })
        #expect(!merged.contains { $0.startChar == 6 && $0.length == 3 })
        let sorted = merged.sorted { $0.startChar < $1.startChar }
        #expect(merged == sorted)
    }

    @Test func mergeLSPInterpolationTokenReplacesBuiltin() {
        // pyright's interpolation token aligns with our code token —
        // clean replace, strings and delimiters intact, no holes.
        let builtin = pyTokens(#"x = f"hello {name}!""#).tokens
        let lsp = [tok(0, 1, "variable"), tok(13, 4, "parameter")]
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)
        #expect(merged.contains { $0.startChar == 13 && $0.length == 4 && $0.type == "parameter" })
        #expect(merged.contains { $0.type == "string" && $0.startChar == 4 })
        #expect(merged.contains { $0.type == "string" && $0.startChar == 18 })
        #expect(merged.contains { $0.type == "interpolation" && $0.startChar == 12 })
        if merged.count > 1 {
            for k in 1..<merged.count {
                #expect(merged[k - 1].startChar + merged[k - 1].length <= merged[k].startChar)
            }
        }
    }

    @Test func mergeStraddlingTokenEvictsChunkAndMayLeaveGap() {
        // DOCUMENTED behavior: an LSP token straddling a chunk boundary
        // evicts the chunk; [4,10) stays uncolored. Eviction can already
        // leave gaps for any token kind — provenance over coverage; no
        // known server straddles. If one ever does, the fix belongs in
        // the LSP span conversion, not in the merge contract.
        let builtin = pyTokens(#"x = f"hello {name}!""#).tokens
        let lsp = [tok(10, 4, "macro")]           // covers "o␣{n"
        let merged = SyntaxTokenizer.mergeWithLSP(builtin: builtin, lsp: lsp)
        #expect(!merged.contains { $0.type == "string" && $0.startChar == 4 })
        #expect(merged.contains { $0.startChar == 10 && $0.length == 4 })
        #expect(merged.contains { $0.type == "string" && $0.startChar == 18 })
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
        // take nested LSP tokens with it. `x = "plain"`: string [4, 11);
        // l1 [8, 13) crosses the closing quote and evicts the string;
        // l2 [5, 6) is nested but must survive.
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

    /// Adversarial input (machine junk): thousands of unmatched openers
    /// on one line. The per-line field-scan budget degrades them to
    /// plain text early — the whole literal stays ONE string token,
    /// invariants hold, and the pass is bounded (~3·n) instead of
    /// 512·n. Pinned by construction: any regression to quadratic
    /// behavior makes this test visibly slow.
    @Test func adversarialOpenersDegradeToPlainString() {
        let line = "x = f\"" + String(repeating: "{ a", count: 3000) + "\""
        let ts = pyTokens(line).tokens
        #expect(has(ts, 4, line.count - 4, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
        #expect(!ts.contains { $0.type == "variable" && $0.startChar >= 4 })
    }

    /// A VALID field past fieldScanLimit (a >512-char single-line
    /// dict literal, say) is malformed by the limit's definition: the
    /// opener degrades to text (INV1) and the literal stays one string
    /// token. Documented degradation, deterministic.
    @Test func overlongValidFieldDegradesToString() {
        let line = "x = f\"" + "{" + String(repeating: "a", count: 600) + "}\""
        let ts = pyTokens(line).tokens
        #expect(has(ts, 4, line.count - 4, "string"))
        #expect(!ts.contains { $0.type == "interpolation" })
    }

    // MARK: - the string-state ladder (extendStringStates)

    /// Entry N is the state AFTER line N: an unclosed `"""` leaves the
    /// ladder active past its line, the closing line resets it — the
    /// two facts every consumer (the editor per tab, Highlight.Session)
    /// threads through tokenize.
    @Test func ladderTracksMultilineStringAcrossLines() {
        let buffer = PieceTable(text: "let s = \"\"\"\nline inside\ncloses here\"\"\"\nlet x = 1\n")
        var states: [SyntaxTokenizer.MultilineStringState] = []
        SyntaxTokenizer.extendStringStates(&states, through: 3, buffer: buffer,
                                           keywords: SyntaxTokenizer.swiftKeywords,
                                           literals: SyntaxTokenizer.swiftLiterals,
                                           syntax: SyntaxTokenizer.syntax(for: "swift"))
        #expect(states.count == 4)
        // Swift's gate is .always — the ladder carries interpolating.
        #expect(states[0] == .active(ruleIndex: 0, interpolating: true)) // opened on line 0
        #expect(states[1] == .active(ruleIndex: 0, interpolating: true)) // still open
        #expect(states[2] == .none)                 // closed on line 2
        #expect(states[3] == .none)
    }

    /// Extension is INCREMENTAL: extending step by step lands on the
    /// same ladder as one shot through the end (the preview scrolls
    /// this way — the ladder must never recompute or fork).
    @Test func ladderExtendsIncrementallyIdentically() {
        let buffer = PieceTable(text: "x = '''a\nb\n'''\ny = 2\n")
        var stepwise: [SyntaxTokenizer.MultilineStringState] = []
        SyntaxTokenizer.extendStringStates(&stepwise, through: 1, buffer: buffer,
                                           keywords: SyntaxTokenizer.pythonKeywords,
                                           literals: SyntaxTokenizer.pythonLiterals,
                                           syntax: SyntaxTokenizer.syntax(for: "py"))
        SyntaxTokenizer.extendStringStates(&stepwise, through: 3, buffer: buffer,
                                           keywords: SyntaxTokenizer.pythonKeywords,
                                           literals: SyntaxTokenizer.pythonLiterals,
                                           syntax: SyntaxTokenizer.syntax(for: "py"))
        var oneshot: [SyntaxTokenizer.MultilineStringState] = []
        SyntaxTokenizer.extendStringStates(&oneshot, through: 3, buffer: buffer,
                                           keywords: SyntaxTokenizer.pythonKeywords,
                                           literals: SyntaxTokenizer.pythonLiterals,
                                           syntax: SyntaxTokenizer.syntax(for: "py"))
        #expect(stepwise == oneshot)
        // Python's rules sort by opener length — both are 3, so """"
        // keeps index 0 and ''' is index 1. No f prefix — not
        // interpolating.
        #expect(stepwise == [.active(ruleIndex: 1, interpolating: false),
                             .active(ruleIndex: 1, interpolating: false),
                             .none, .none])
    }

    /// VS Code-parity huge-line guard: at/beyond lineTokenizeLimit a
    /// line is not tokenized at all — zero tokens, and the ladder
    /// state passes through UNCHANGED (the state at the beginning of
    /// the line, like nullTokenizeEncoded). The JSON path guards too —
    /// a minified one-line JSON is the common giant line.
    @Test func hugeLineRendersPlainWithStatePassthrough() {
        let huge = String(repeating: "a", count: SyntaxTokenizer.lineTokenizeLimit)
        let (ts, state) = pyTokens(huge)
        #expect(ts.isEmpty)
        #expect(state == .none)
        let (ts2, state2) = pyTokens(huge, initial: .active(ruleIndex: 0, interpolating: true))
        #expect(ts2.isEmpty)
        #expect(state2 == .active(ruleIndex: 0, interpolating: true))
        // Just under the limit tokenizes normally.
        let ok = String(repeating: "a", count: SyntaxTokenizer.lineTokenizeLimit - 1)
        #expect(!pyTokens(ok).tokens.isEmpty)
        #expect(SyntaxTokenizer.tokenizeJSON(lineChars: Array(huge), lineNum: 0).isEmpty)
    }

    /// The ladder threads THROUGH a huge line: a multiline string open
    /// above it stays open, and closes on the line after it — the
    /// guard never invents or drops state.
    @Test func ladderPassesThroughHugeLine() {
        let huge = String(repeating: "b", count: SyntaxTokenizer.lineTokenizeLimit)
        let buffer = PieceTable(text: "let s = \"\"\"\n" + huge + "\ncloses here\"\"\"\nlet x = 1\n")
        var states: [SyntaxTokenizer.MultilineStringState] = []
        SyntaxTokenizer.extendStringStates(&states, through: 3, buffer: buffer,
                                           keywords: SyntaxTokenizer.swiftKeywords,
                                           literals: SyntaxTokenizer.swiftLiterals,
                                           syntax: SyntaxTokenizer.syntax(for: "swift"))
        #expect(states[0] == .active(ruleIndex: 0, interpolating: true)) // opened on line 0
        #expect(states[1] == .active(ruleIndex: 0, interpolating: true)) // huge line — passthrough
        #expect(states[2] == .none)                 // closed on line 2
        #expect(states[3] == .none)
    }

    /// `through` beyond the last line stops at the buffer's end — the
    /// walk never asks for a line that does not exist.
    @Test func ladderStopsAtBufferEnd() {
        let buffer = PieceTable(text: "a\nb\n")
        var states: [SyntaxTokenizer.MultilineStringState] = []
        SyntaxTokenizer.extendStringStates(&states, through: 100, buffer: buffer,
                                           keywords: [], literals: [],
                                           syntax: .default)
        #expect(states.count == 3) // lines 0, 1, 2 (the trailing empty)
    }
}
