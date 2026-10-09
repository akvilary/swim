/// Incremental scanner for a bracketed-paste payload — the bytes a
/// terminal sends between the ESC[200~ start marker and the ESC[201~
/// end marker. Bytes are fed one at a time (the reader blocks on the
/// tty and cannot know upfront how much is coming), so the scanner
/// matches the end marker incrementally: a payload that merely starts
/// like the marker (a lone ESC, "ESC[2") is kept as content, not
/// swallowed. Pasted newlines arrive as CR or CRLF depending on the
/// terminal; both are normalized to "\n".
public enum BracketedPaste {

    public enum FeedResult: Equatable {
        /// The byte was content (or part of a tentative marker match);
        /// keep feeding.
        case needMore
        /// The end marker is complete; the payload is final.
        case done(String)
    }

    public struct Scanner {
        private static let endMarker: [UInt8] = [27, 91, 50, 48, 49, 126] // ESC [ 2 0 1 ~
        private var payload: [UInt8] = []
        private var matchIdx = 0

        public init() {}

        /// Feeds one payload byte. The end-marker bytes themselves are
        /// never part of the result.
        public mutating func feed(_ b: UInt8) -> FeedResult {
            if matchIdx < Self.endMarker.count && b == Self.endMarker[matchIdx] {
                matchIdx += 1
                if matchIdx == Self.endMarker.count {
                    return .done(Self.normalize(payload))
                }
            } else {
                if matchIdx > 0 {
                    // The tentative marker match turned out to be
                    // content after all — flush it into the payload
                    // before handling `b`. A byte equal to the marker's
                    // head restarts the match (payload may hold "…ESC ESC [201~").
                    payload.append(contentsOf: Self.endMarker[0..<matchIdx])
                    matchIdx = 0
                }
                if b == Self.endMarker[0] {
                    matchIdx = 1
                } else {
                    payload.append(b)
                }
            }
            return .needMore
        }

        /// What has arrived so far — for a stream that ends (EOF)
        /// before the end marker: the payload plus any bytes still
        /// sitting in the tentative match.
        public var partialText: String {
            var bytes = payload
            if matchIdx > 0 { bytes.append(contentsOf: Self.endMarker[0..<matchIdx]) }
            return Self.normalize(bytes)
        }

        /// CR and CRLF both become LF — stdlib `replacing` (SE-0357,
        /// Swift 5.7), no Foundation. CRLF first, then any lone CR
        /// left; a CR can never appear inside a UTF-8 multibyte
        /// sequence (continuation bytes are >= 0x80), so plain
        /// replacement is byte-safe here.
        private static func normalize(_ bytes: [UInt8]) -> String {
            String(decoding: bytes, as: UTF8.self)
                .replacing("\r\n", with: "\n")
                .replacing("\r", with: "\n")
        }
    }
}
