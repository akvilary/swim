import Foundation

/// Highlighting of an immutable file's visible window — the preview
/// panel's whole pipeline behind one door: language routing (code /
/// JSON / markdown, by file extension), viewport-scoped tokenization
/// (only the lines shown, only when asked — nothing is pre-colored),
/// the multi-line-string state ladder (extended incrementally; the
/// content never changes, so the ladder never invalidates), and the
/// markdown viewport cache. The editor's builtin layer runs the same
/// underlying tokenizers (SyntaxTokenizer / MarkdownTokenizer) —
/// coloring parity holds by construction: both surfaces call the same
/// functions.
///
/// A Session is a UI-loop object (like the windows that own it); it
/// never crosses threads. The content is immutable BY CONSTRUCTION:
/// the PieceTable is private and callers see only the read surface —
/// the ladder's and the caches' eternal validity rests on that, so no
/// code can silently invalidate them. Colors are NOT this module's
/// concern (SwimCore has no palette): the app maps token types to
/// Theme colors (Theme.color(forToken:) — the editor's full map; the
/// preview keeps a lexical subset).
public enum Highlight {

    /// The editor's builtin guard, mirrored: beyond this many lines no
    /// builtin coloring — the state ladder is one entry per line, and
    /// the bound keeps its memory finite. Huge files render plain.
    public static let lineLimit = 50_000

    /// One file's highlighting session over an immutable snapshot.
    public final class Session {
        private let buffer: PieceTable
        private let isJSON: Bool
        private let isMD: Bool
        private let plain: Bool
        private let keywords: Set<String>
        private let literals: Set<String>
        private let syntax: SyntaxTokenizer.LanguageSyntax
        /// Entry N holds the state AFTER line N; line N is tokenized
        /// starting from states[N - 1] (SyntaxTokenizer.
        /// extendStringStates — the shared walk). Extend-only: the
        /// content is immutable, so no entry ever goes stale.
        private var stringStates: [SyntaxTokenizer.MultilineStringState] = []
        private var markdownCache = MarkdownTokenizer.Cache()

        public init(text: String, fileExt: String) {
            self.buffer = PieceTable(text: text)
            self.isJSON = fileExt == "json"
            self.isMD = MarkdownTokenizer.isMarkdown(fileExt)
            self.plain = buffer.lineCount >= Highlight.lineLimit
            self.keywords = (!plain && !isMD && !isJSON) ? SyntaxTokenizer.keywords(for: fileExt) : []
            self.literals = (!plain && !isMD && !isJSON) ? SyntaxTokenizer.valueLiterals(for: fileExt) : []
            self.syntax = SyntaxTokenizer.syntax(for: fileExt)
        }

        public var lineCount: Int { buffer.lineCount }

        public func getLine(_ line: Int) -> String { buffer.getLine(line) }

        public func getLineChars(_ line: Int) -> [Character] { buffer.getLineChars(line) }

        /// Tokens for the visible window — ONE call per draw. Markdown
        /// is window-shaped (fenced blocks span lines; the viewport
        /// cache fast-forwards); code and JSON tokenize line by line,
        /// the string-state ladder extended lazily through the window's
        /// end. Files past `lineLimit` and out-of-range windows give an
        /// empty map — the caller renders plain text.
        public func tokens(scrollY: Int, height: Int) -> [Int: [SemanticToken]] {
            guard !plain, scrollY >= 0, height > 0 else { return [:] }
            let last = min(scrollY + height, buffer.lineCount)
            guard scrollY < last else { return [:] }
            if isMD {
                let md = MarkdownTokenizer.tokenizeVisible(
                    buffer: buffer, scrollY: scrollY, height: last - scrollY,
                    cache: &markdownCache)
                var byLine = [Int: [SemanticToken]]()
                byLine.reserveCapacity(last - scrollY)
                for token in md {
                    byLine[token.line, default: []].append(token)
                }
                return byLine
            }
            // The ladder only pays for languages with multi-line
            // string rules (the editor skips it the same way); JSON is
            // stateless per line.
            if !syntax.mlRules.isEmpty {
                SyntaxTokenizer.extendStringStates(
                    &stringStates, through: last - 1, buffer: buffer,
                    keywords: keywords, literals: literals, syntax: syntax)
            }
            var byLine = [Int: [SemanticToken]]()
            byLine.reserveCapacity(last - scrollY)
            for lineNum in scrollY..<last {
                let initial: SyntaxTokenizer.MultilineStringState =
                    lineNum > 0 && lineNum - 1 < stringStates.count ? stringStates[lineNum - 1] : .none
                byLine[lineNum] = isJSON
                    ? SyntaxTokenizer.tokenizeJSON(lineChars: buffer.getLineChars(lineNum), lineNum: lineNum)
                    : SyntaxTokenizer.tokenize(chars: buffer.getLineChars(lineNum), lineNum: lineNum,
                                                keywords: keywords, syntax: syntax,
                                                initialState: initial, literals: literals).tokens
            }
            return byLine
        }
    }
}
