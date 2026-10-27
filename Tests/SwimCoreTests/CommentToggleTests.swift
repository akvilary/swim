import Testing
import SwimCore

/// CommentToggle — the pure half of the visual `/`. The fixed product
/// semantics: the FIRST NON-BLANK line decides the direction for the whole
/// selection — a blank line carries no marker and must not decide
/// (under nesting it would stack a layer per press); leading blanks
/// are ignored; ADD leaves no exceptions — an already-commented line
/// NESTS (one more token at the shared column, its own marker and
/// indent untouched), the untoggle stripping exactly the outer one
/// (byte-exact restore); REMOVE drops the token plus
/// one following space, conservatively (alignment and a previous add's
/// padding survive); at the indent anchor all markers form ONE column —
/// the leftmost non-blank indent of the selection, deeper lines keeping
/// their indent after the marker; blanks in the middle never get a
/// marker at the indent anchor but DO get a padded one at a column
/// anchor (the rectangle's marker column stays continuous).
@Suite struct CommentToggleTests {

    // MARK: - Direction: the first non-blank line decides

    @Test func firstLineUnmarkedMeansAdd() {
        let p = CommentToggle.plan(lines: ["let a = 1", "let b = 2"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .add)
        #expect(p.plans.map(\.text) == ["// let a = 1", "// let b = 2"])
        #expect(p.plans.allSatisfy { $0.changed })
        #expect(p.plans[0].editAt == 0)
    }

    @Test func firstLineMarkedMeansRemove() {
        let p = CommentToggle.plan(lines: ["// let a = 1", "// let b = 2"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .remove)
        #expect(p.plans.map(\.text) == ["let a = 1", "let b = 2"])
    }

    @Test func blankFirstLineIsNotTheDecider() {
        // The FIRST NON-BLANK line decides: a blank line carries no
        // marker and must not force add (under nesting it would stack
        // a layer per press, the untoggle never firing).
        let p = CommentToggle.plan(lines: ["", "// a", "// b"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .remove)
        #expect(p.plans.map { $0.text } == ["", "a", "b"])
    }

    @Test func addNestsOntoMarkedLines() {
        // ADD leaves no exceptions: the unmarked line gets its marker,
        // the already-marked one NESTS (a second token at the shared
        // column, its own marker untouched below).
        let p = CommentToggle.plan(lines: ["", "x", "// y"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .add)
        #expect(p.plans.map { $0.text } == ["", "// x", "// // y"])
        #expect(p.plans.map { $0.changed } == [false, true, true])
    }

    @Test func whitespaceOnlyIsBlank() {
        // Spaces/tabs-only lines count as blank: ignored as leading…
        let p = CommentToggle.plan(lines: ["  ", "\t", "x"],
                                   token: "//", anchor: .indent)
        #expect(p.plans.map(\.changed) == [false, false, true])
        #expect(p.plans[2].text == "// x")
    }

    // MARK: - Indent anchor: ONE column — the leftmost non-blank position

    @Test func indentAddAlignsMarkersAtTheLeftmostIndent() {
        // The column is the leftmost non-blank position; deeper lines
        // keep their indent riding AFTER the marker.
        let p = CommentToggle.plan(lines: ["if x {", "    a", "\tb", "}"],
                                   token: "//", anchor: .indent)
        #expect(p.plans.map { $0.text } == ["// if x {", "//     a", "// \tb", "// }"])
        #expect(p.plans.allSatisfy { $0.editAt == 0 })
    }

    @Test func indentAddAlignsAtNestedIndent() {
        // The leftmost non-blank is at column 2 — every marker there.
        let p = CommentToggle.plan(lines: ["  if x {", "      a", "  }"],
                                   token: "//", anchor: .indent)
        #expect(p.plans.map { $0.text } == ["  // if x {", "  //     a", "  // }"])
        #expect(p.plans.allSatisfy { $0.editAt == 2 })
    }

    @Test func indentColumnIgnoresBlankLines() {
        // A blank line has no content position — it must not drag the
        // column to zero, and it never receives a marker.
        let p = CommentToggle.plan(lines: ["    a", "", "   ", "    b"],
                                   token: "//", anchor: .indent)
        #expect(p.plans.map { $0.text } == ["    // a", "", "   ", "    // b"])
        #expect(p.plans.map { $0.changed } == [true, false, false, true])
    }

    @Test func indentColumnCountsMarkedLines() {
        // The standing marker at column 0 participates in the minimum,
        // and ADD nests onto it — everything lands under one column.
        let p = CommentToggle.plan(lines: ["    x", "// b"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .add)
        #expect(p.plans.map { $0.text } == ["//     x", "// // b"])
        #expect(p.plans.map { $0.changed } == [true, true])
    }

    @Test func nestingScenarioRoundTripsByteExact() {
        // The product scenario: line 1 uncommented, lines 2-3 commented
        // with their own indent. ADD nests one more marker at the shared
        // column (nothing moved); the untoggle strips exactly the outer
        // one — the former state returns byte-for-byte.
        let lines = ["x", "    // b", "    // c"]
        let added = CommentToggle.plan(lines: lines, token: "//", anchor: .indent)
        #expect(added.direction == .add)
        #expect(added.plans.map { $0.text } == ["// x", "//     // b", "//     // c"])
        let removed = CommentToggle.plan(lines: added.plans.map { $0.text },
                                         token: "//", anchor: .indent)
        #expect(removed.direction == .remove)
        #expect(removed.plans.map { $0.text } == lines)
    }

    @Test func allBlankSelectionHasNoDecider() {
        let p = CommentToggle.plan(lines: ["", "   ", "\t"],
                                   token: "//", anchor: .indent)
        #expect(p.plans.allSatisfy { !$0.changed })
    }

    @Test func columnAnchorNestsAtTheBlockColumn() {
        // Blockwise ADD nests the same way: a row already marked AT the
        // column gets one more token there; the untoggle strips it.
        let lines = ["y = 2", "let // a = 1"]
        let added = CommentToggle.plan(lines: lines, token: "//",
                                        anchor: .column(4, tabWidth: 4))
        #expect(added.direction == .add)
        #expect(added.plans.map { $0.text } == ["y = // 2", "let // // a = 1"])
        let removed = CommentToggle.plan(lines: added.plans.map { $0.text }, token: "//",
                                         anchor: .column(4, tabWidth: 4))
        #expect(removed.plans.map { $0.text } == lines)
    }

    @Test func indentAlignedRoundTripIsExact() {
        let lines = ["  if x {", "      a = 1", "  }"]
        let added = CommentToggle.plan(lines: lines, token: "//", anchor: .indent)
        #expect(added.plans.allSatisfy { $0.editAt == 2 })
        let removed = CommentToggle.plan(lines: added.plans.map { $0.text },
                                         token: "//", anchor: .indent)
        #expect(removed.plans.map { $0.text } == lines)
    }

    @Test func indentAddSkipsBlankLinesInTheMiddle() {
        let p = CommentToggle.plan(lines: ["a", "", "   ", "b"],
                                   token: "#", anchor: .indent)
        #expect(p.plans.map(\.text) == ["# a", "", "   ", "# b"])
        #expect(p.plans.map(\.changed) == [true, false, false, true])
    }

    @Test func indentRemoveVariants() {
        // token+one space; bare token; two spaces keep one;
        // marker-only empties the line; one layer of nesting at a time;
        // a `///` doc comment loses exactly the `//` token.
        let p = CommentToggle.plan(lines: ["// a", "#b", "#  c", "//", "// // x", "/// doc"],
                                   token: "//", anchor: .indent)
        #expect(p.direction == .remove)
        #expect(p.plans[0].text == "a")
        // The `#b` line does not carry the `//` token at the anchor —
        // REMOVE leaves it alone (direction is global, per-line
        // applicability decides).
        #expect(p.plans[1].text == "#b")
        #expect(p.plans[1].changed == false)
        #expect(p.plans[2].text == "#  c")
        #expect(p.plans[3].text == "")
        #expect(p.plans[4].text == "// x")
        #expect(p.plans[5].text == "/ doc")
    }

    @Test func removeDropsAtMostOneSpace() {
        let p = CommentToggle.plan(lines: ["  //  code"], token: "//", anchor: .indent)
        #expect(p.plans[0].text == "   code")
    }

    // MARK: - Round trip: comment then uncomment == original (clean code)

    @Test func indentRoundTripIsExact() {
        let corpus = [
            ["let a = 1"],
            ["if x {", "    a = f(1)", "\tb = 2", "}", "", "tail"],
            ["x = \"// not at anchor\"", "深い x", "y\tz"],
        ]
        for lines in corpus {
            let added = CommentToggle.plan(lines: lines, token: "//", anchor: .indent)
            let removed = CommentToggle.plan(lines: added.plans.map(\.text),
                                             token: "//", anchor: .indent)
            #expect(removed.plans.map(\.text) == lines)
        }
    }

    // MARK: - Column anchor: the rectangle's left edge in display cells

    @Test func columnAddInsertsAtTheBoundary() {
        // Column 4 lands right after "let " — the marker splits the
        // line; the left part stays untouched.
        let p = CommentToggle.plan(lines: ["let a = 1"], token: "//",
                                   anchor: .column(4, tabWidth: 4))
        #expect(p.direction == .add)
        #expect(p.plans[0].text == "let // a = 1")
        #expect(p.plans[0].editAt == 4)
    }

    @Test func columnAddPadsShortLines() {
        let p = CommentToggle.plan(lines: ["ab"], token: "//",
                                   anchor: .column(5, tabWidth: 4))
        // Padded to the column, bare token at the line's end (no
        // trailing space).
        #expect(p.plans[0].text == "ab   //")
        #expect(p.plans[0].editAt == 5)
    }

    @Test func columnAddKeepsTheColumnContinuous() {
        // Middle and trailing blanks get the padded marker — the
        // rectangle participates from the first non-blank line on.
        let p = CommentToggle.plan(lines: ["x", "", "y"], token: "//",
                                   anchor: .column(0, tabWidth: 4))
        #expect(p.plans.map(\.text) == ["// x", "//", "// y"])
    }

    @Test func columnAddSkipsLeadingBlanks() {
        let p = CommentToggle.plan(lines: ["", "  ", "x"], token: "//",
                                   anchor: .column(0, tabWidth: 4))
        #expect(p.direction == .add)
        #expect(p.plans.map(\.text) == ["", "  ", "// x"])
    }

    @Test func columnMarkerLandsAfterAStraddlingTab() {
        // The tab covers cells 0..4, the block's edge is at 2 — the
        // marker cannot split a tab: it lands on the boundary after it
        // (the same insertion rule as blockwise paste).
        let p = CommentToggle.plan(lines: ["\tcode"], token: "//",
                                   anchor: .column(2, tabWidth: 4))
        #expect(p.plans[0].text == "\t// code")
        #expect(p.plans[0].editAt == 1)
    }

    @Test func columnRemoveStripsMarkerKeepsPadding() {
        // Conservative removal: the padding a previous add introduced
        // stays (pressing again is stable from the second cycle).
        let p = CommentToggle.plan(lines: ["ab   //"], token: "//",
                                   anchor: .column(5, tabWidth: 4))
        #expect(p.direction == .remove)
        #expect(p.plans[0].text == "ab   ")
        #expect(p.plans[0].editAt == 5)
    }

    @Test func columnRemoveWithFollowingSpace() {
        let p = CommentToggle.plan(lines: ["let // a = 1"], token: "//",
                                   anchor: .column(4, tabWidth: 4))
        #expect(p.plans[0].text == "let a = 1")
    }

    @Test func columnShortFirstLineIsTheDecider() {
        // A short non-blank line is NOT a leading blank: it decides
        // (no content at the column ⇒ no token ⇒ add) and participates.
        let p = CommentToggle.plan(lines: ["ab", "code here"], token: "//",
                                   anchor: .column(8, tabWidth: 4))
        #expect(p.direction == .add)
        #expect(p.plans[0].text == "ab      //")
        #expect(p.plans[1].text == "code her// e")
    }

    @Test func columnRoundTripForContentAtTheColumn() {
        let lines = ["let a = 1", "let bb = 2"]
        let added = CommentToggle.plan(lines: lines, token: "//",
                                       anchor: .column(4, tabWidth: 4))
        let removed = CommentToggle.plan(lines: added.plans.map(\.text), token: "//",
                                         anchor: .column(4, tabWidth: 4))
        #expect(removed.plans.map(\.text) == lines)
    }

    // MARK: - Deterministic property campaign (seeded, house style —
    // the PieceTable campaign precedent): random lines over an
    // alphabet of the dangerous characters, both tokens, both anchors.
    // Structural invariants: one plan per line, no line breaks inside
    // a plan, `changed` never lies. The semantic one: the toggle is a
    // 2-CYCLE FROM THE SECOND APPLICATION — out4 == out2 and
    // out5 == out3 for every input. The first application may
    // NORMALIZE once (a pre-existing content space right after the
    // marker position is consumed by the first remove — the documented
    // `#foo` → `# foo` class, "stable from the second cycle" in the
    // module contract); after that the add/remove pair is an exact
    // involution, never a drift.
    @Test func randomCampaignTwoCycleFromSecondApplication() {
        var seed: UInt64 = 0x5EE0
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed
        }
        let pieces = ["a", "b", "中", " ", "  ", "\t", "//", "#", "x", "=", "// ", "# "]
        for _ in 0..<300 {
            let lineCount = 1 + Int(next() % 6)
            var lines = [String]()
            for _ in 0..<lineCount {
                var line = ""
                for _ in 0..<Int(next() % 10) {
                    line += pieces[Int(next() % UInt64(pieces.count))]
                }
                lines.append(line)
            }
            let token = next() % 2 == 0 ? "//" : "#"
            let anchor: CommentToggle.Anchor = next() % 2 == 0
                ? .indent
                : .column(Int(next() % 9), tabWidth: 4)

            let p1 = CommentToggle.plan(lines: lines, token: token, anchor: anchor)
            // Structural: index-aligned, terminator-free, honest flags.
            #expect(p1.plans.count == lines.count)
            for (plan, original) in zip(p1.plans, lines) {
                #expect(!plan.text.contains("\n"))
                #expect(plan.changed == (plan.text != original))
            }
            // Semantic: out4 == out2 and out5 == out3 — the toggle
            // alternates exactly from the second application on.
            let out1 = p1.plans.map { $0.text }
            let p2 = CommentToggle.plan(lines: out1, token: token, anchor: anchor)
            let out2 = p2.plans.map { $0.text }
            // Involution (indent anchor): an add is undone EXACTLY —
            // remove strips precisely the token+space pair add laid at
            // the shared column, a previously commented line's own
            // marker surviving below.
            if case .indent = anchor, p1.direction == .add {
                #expect(out2 == lines)
            }
            let p3 = CommentToggle.plan(lines: out2, token: token, anchor: anchor)
            let out3 = p3.plans.map { $0.text }
            let p4 = CommentToggle.plan(lines: out3, token: token, anchor: anchor)
            #expect(p4.plans.map { $0.text } == out2)
            let p5 = CommentToggle.plan(lines: p4.plans.map { $0.text }, token: token, anchor: anchor)
            #expect(p5.plans.map { $0.text } == out3)
        }
    }

    // MARK: - Degenerate inputs: a public entry point never crashes

    @Test func emptySelectionAndEmptyTokenAreInert() {
        // lines: [] — no decider, no plans, no trap.
        let empty = CommentToggle.plan(lines: [], token: "//", anchor: .indent)
        #expect(empty.direction == .add && empty.plans.isEmpty)
        // token: "" — matches everything by prefix, so it must neither
        // mark nor strip anything (a stray space included).
        let hollow = CommentToggle.plan(lines: ["a b", "  c"], token: "", anchor: .indent)
        #expect(hollow.direction == .add)
        #expect(hollow.plans.map(\.text) == ["a b", "  c"])
        #expect(hollow.plans.allSatisfy { !$0.changed })
    }

    // MARK: - The token table: syntax(for:) is the single authority

    @Test func lineCommentTokenPerExtension() {
        let slashSlash = ["swift", "c", "h", "cpp", "cc", "cxx", "hpp", "hxx",
                          "js", "ts", "jsx", "tsx", "dart", "rs", "go", "cs"]
        let hash = ["py", "pyw", "pyi", "sh", "bash", "yaml", "yml", "toml", "rb"]
        for ext in slashSlash {
            #expect(SyntaxTokenizer.syntax(for: ext).lineComment == "//",
                    "extension \(ext)")
        }
        for ext in hash {
            #expect(SyntaxTokenizer.syntax(for: ext).lineComment == "#",
                    "extension \(ext)")
        }
        // No line comment — the honest nil beats a guessed token.
        for ext in ["json", "md", "markdown", "txt", "", "unknownxyz", "SWIFT"] {
            #expect(SyntaxTokenizer.syntax(for: ext).lineComment == nil,
                    "extension \(ext)")
        }
    }
}
