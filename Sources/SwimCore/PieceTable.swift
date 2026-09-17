import Foundation

struct Piece {
    var start: Int
    var length: Int
    var isAdd: Bool

    var range: Range<Int> { start..<(start + length) }
}

public final class PieceTable {
    private var original = [UInt8]()
    private var addBuffer = [UInt8]()
    private var pieces = [Piece]()
    private var lineStarts = [Int]()
    private var cachedLineNum: Int = -1
    private var cachedLineStr: String = ""
    private var cachedLineCharsNum: Int = -1
    private var cachedLineChars: [Character] = []
    public private(set) var totalLength: Int = 0

    public var lineCount: Int {
        lineStarts.count
    }

    public init(data: [UInt8]) {
        original = data
        pieces = [Piece(start: 0, length: data.count, isAdd: false)]
        totalLength = data.count
        rebuildLineIndex()
    }

    public convenience init(text: String) {
        self.init(data: [UInt8](text.utf8))
    }

    public static func fromFile(_ path: String) -> PieceTable? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return PieceTable(data: [UInt8](data))
    }

    private func buffer(for piece: Piece) -> [UInt8] {
        piece.isAdd ? addBuffer : original
    }

    private func scanNewlines(in piece: Piece, fromLocal localStart: Int, baseOffset: Int, into lineStarts: inout [Int]) {
        let buf = buffer(for: piece)
        let scanLength = piece.length - localStart
        buf.withUnsafeBufferPointer { ptr in
            let p = ptr.baseAddress! + piece.start + localStart
            for i in 0..<scanLength {
                if p[i] == 10 {
                    lineStarts.append(baseOffset + i + 1)
                }
            }
        }
    }

    private func rebuildLineIndex() {
        lineStarts = [Int]()
        lineStarts.reserveCapacity(max(16, totalLength / 30))
        lineStarts.append(0)
        var offset = 0
        for piece in pieces {
            scanNewlines(in: piece, fromLocal: 0, baseOffset: offset, into: &lineStarts)
            offset += piece.length
        }
    }

    private func rebuildLineIndex(fromOffset startOffset: Int) {
        let startIdx = binarySearchLineIndex(startOffset)
        lineStarts.removeSubrange(startIdx...)

        var offset = startOffset
        var pieceOffset = 0

        for piece in pieces {
            let pieceEnd = pieceOffset + piece.length
            if startOffset >= pieceEnd {
                pieceOffset += piece.length
                continue
            }
            let localStart = max(0, startOffset - pieceOffset)
            scanNewlines(in: piece, fromLocal: localStart, baseOffset: offset, into: &lineStarts)
            offset += piece.length - localStart
            pieceOffset += piece.length
        }
    }

    private func binarySearchLineIndex(_ offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset { lo = mid + 1 }
            else { hi = mid }
        }
        return lo
    }

    public func lineStart(line: Int) -> Int {
        guard line >= 0 && line < lineStarts.count else { return 0 }
        return lineStarts[line]
    }

    public func lineEnd(line: Int) -> Int {
        guard line >= 0 else { return 0 }
        if line + 1 < lineStarts.count { return lineStarts[line + 1] }
        return totalLength
    }

    public func lineLength(line: Int) -> Int {
        lineEnd(line: line) - lineStart(line: line)
    }

    public func offsetToLineCol(_ offset: Int) -> (line: Int, col: Int) {
        let idx = binarySearchLineIndex(offset) - 1
        let line = max(0, idx)
        let col = offset - lineStarts[line]
        return (line, col)
    }

    public func insert(_ text: String, at offset: Int) {
        guard !text.isEmpty else { return }
        cachedLineNum = -1
        cachedLineCharsNum = -1
        let data = [UInt8](text.utf8)
        totalLength += data.count
        let addStart = addBuffer.count
        addBuffer.append(contentsOf: data)

        let (pieceIdx, localOffset) = findPieceAndLocalOffset(offset)

        if pieces.isEmpty {
            pieces.append(Piece(start: addStart, length: data.count, isAdd: true))
        } else if localOffset == 0 {
            pieces.insert(Piece(start: addStart, length: data.count, isAdd: true), at: pieceIdx)
        } else if localOffset == pieces[pieceIdx].length {
            pieces.insert(Piece(start: addStart, length: data.count, isAdd: true), at: pieceIdx + 1)
        } else {
            let p = pieces[pieceIdx]
            let before = Piece(start: p.start, length: localOffset, isAdd: p.isAdd)
            let inserted = Piece(start: addStart, length: data.count, isAdd: true)
            let after = Piece(start: p.start + localOffset, length: p.length - localOffset, isAdd: p.isAdd)
            pieces.replaceSubrange(pieceIdx...pieceIdx, with: [before, inserted, after])
        }

        rebuildLineIndex(fromOffset: offset)
    }

    public func delete(at offset: Int, length: Int) {
        guard length > 0, offset < totalLength else { return }
        cachedLineNum = -1
        cachedLineCharsNum = -1

        // Phase 1 — plan the cuts against the ORIGINAL piece layout, in
        // original coordinates. Mutating pieces while walking (the old
        // approach) mixes coordinate systems: each trim shifts every
        // following byte left, so `currentOffset += deleteLen` overshoots
        // and the walk skips pieces inside the range, deleting bytes
        // PAST the requested range — silent content corruption with
        // correct length bookkeeping (found by a randomized stress test:
        // dd straddling piece boundaries after heavy editing).
        var cuts: [(pieceIdx: Int, localStart: Int, localEnd: Int)] = []
        var remaining = length
        var pieceOffset = 0
        var i = 0
        while remaining > 0 && i < pieces.count {
            let piece = pieces[i]
            let pieceEnd = pieceOffset + piece.length
            if offset >= pieceEnd {
                pieceOffset = pieceEnd
                i += 1
                continue
            }
            // offset < pieceEnd and offset >= pieceOffset: the range
            // starts inside this piece (or exactly at its head).
            let localStart = max(0, offset - pieceOffset)
            let cut = min(remaining, piece.length - localStart)
            cuts.append((i, localStart, localStart + cut))
            remaining -= cut
            pieceOffset = pieceEnd
            i += 1
        }

        guard !cuts.isEmpty else { return }

        // Phase 2 — apply the cuts back-to-front: piece indices of earlier
        // cuts are never invalidated by later (higher-index) edits, and a
        // split inserts its after-piece above the remaining cuts.
        for cut in cuts.reversed() {
            var piece = pieces[cut.pieceIdx]
            if cut.localStart == 0 && cut.localEnd == piece.length {
                pieces.remove(at: cut.pieceIdx)
            } else if cut.localStart == 0 {
                piece.start += cut.localEnd
                piece.length -= cut.localEnd
                pieces[cut.pieceIdx] = piece
            } else if cut.localEnd == piece.length {
                piece.length = cut.localStart
                pieces[cut.pieceIdx] = piece
            } else {
                let before = Piece(start: piece.start, length: cut.localStart, isAdd: piece.isAdd)
                let after = Piece(start: piece.start + cut.localEnd, length: piece.length - cut.localEnd, isAdd: piece.isAdd)
                pieces.replaceSubrange(cut.pieceIdx...cut.pieceIdx, with: [before, after])
            }
        }

        totalLength -= (length - remaining)
        rebuildLineIndex(fromOffset: offset)
    }

    private func findPieceAndLocalOffset(_ offset: Int) -> (pieceIdx: Int, localOffset: Int) {
        var accumulated = 0
        for (idx, piece) in pieces.enumerated() {
            if accumulated + piece.length > offset {
                return (idx, offset - accumulated)
            }
            accumulated += piece.length
        }
        if offset == accumulated && !pieces.isEmpty {
            return (pieces.count - 1, pieces.last!.length)
        }
        return (pieces.count, 0)
    }

    public func getChar(at offset: Int) -> UInt8? {
        let (pieceIdx, localOffset) = findPieceAndLocalOffset(offset)
        guard pieceIdx < pieces.count else { return nil }
        let piece = pieces[pieceIdx]
        let buf = buffer(for: piece)
        guard localOffset < buf.count else { return nil }
        return buf[piece.start + localOffset]
    }

    public func getText(range: Range<Int>) -> String {
        var result = [UInt8]()
        result.reserveCapacity(range.count)
        var accumulated = 0

        for piece in pieces {
            if accumulated >= range.upperBound { break }
            let pieceEnd = accumulated + piece.length
            if pieceEnd <= range.lowerBound {
                accumulated += piece.length
                continue
            }
            let buf = buffer(for: piece)
            let localStart = max(0, range.lowerBound - accumulated)
            let localEnd = min(piece.length, range.upperBound - accumulated)
            result.append(contentsOf: buf[piece.start + localStart..<piece.start + localEnd])
            accumulated += piece.length
        }

        return String(bytes: result, encoding: .utf8) ?? ""
    }

    public func getLine(_ lineNum: Int) -> String {
        if lineNum == cachedLineNum { return cachedLineStr }
        guard lineNum >= 0 && lineNum < lineStarts.count else { return "" }
        let start = lineStarts[lineNum]
        let end = lineEnd(line: lineNum)
        let text = getText(range: start..<end)
        // Strip the terminator at BYTE level: "\r\n" is a single grapheme
        // cluster in Swift, so dropLast(2) on the substring would also eat
        // the last visible character of every CRLF line.
        let utf8 = Array(text.utf8)
        var dropCount = 0
        if utf8.last == 10 {
            dropCount = (utf8.count >= 2 && utf8[utf8.count - 2] == 13) ? 2 : 1
        } else if utf8.last == 13 {
            dropCount = 1
        }
        cachedLineNum = lineNum
        cachedLineStr = String(bytes: utf8.dropLast(dropCount), encoding: .utf8) ?? ""
        return cachedLineStr
    }

    public func getLineChars(_ lineNum: Int) -> [Character] {
        if lineNum == cachedLineCharsNum { return cachedLineChars }
        let str = getLine(lineNum)
        let chars = Array(str)
        cachedLineCharsNum = lineNum
        cachedLineChars = chars
        return chars
    }

    public func charToByteOffsetInLine(line: Int, charIndex: Int) -> Int {
        let chars = getLineChars(line)
        var bytePos = 0
        for (idx, char) in chars.enumerated() {
            guard idx < charIndex else { break }
            bytePos += char.isASCII ? 1 : char.utf8.count
        }
        return bytePos
    }

    public func byteToCharOffsetInLine(line: Int, byteOffset: Int) -> Int {
        let chars = getLineChars(line)
        var bytePos = 0
        for (idx, char) in chars.enumerated() {
            if bytePos >= byteOffset { return idx }
            bytePos += char.isASCII ? 1 : char.utf8.count
        }
        return chars.count
    }

    public func utf16Col(line: Int, byteCol: Int) -> Int {
        let chars = getLineChars(line)
        var bytePos = 0
        var units = 0
        for char in chars {
            if bytePos >= byteCol { break }
            bytePos += char.isASCII ? 1 : char.utf8.count
            units += char.isASCII ? 1 : char.utf16.count
        }
        return units
    }

    public func utf16ColForCharIndex(line: Int, charIndex: Int) -> Int {
        let chars = getLineChars(line)
        var units = 0
        var idx = 0
        for char in chars {
            guard idx < charIndex else { break }
            units += char.isASCII ? 1 : char.utf16.count
            idx += 1
        }
        return units
    }

    public func charIndexForUtf16(line: Int, colUtf16: Int) -> Int {
        let chars = getLineChars(line)
        var units = 0
        for (idx, char) in chars.enumerated() {
            let next = units + (char.isASCII ? 1 : char.utf16.count)
            if next > colUtf16 { return idx }
            units = next
        }
        return chars.count
    }

    public func search(_ query: String, from offset: Int = 0) -> Int? {
        guard !query.isEmpty else { return nil }
        let queryBytes = [UInt8](query.utf8)
        let queryLen = queryBytes.count
        guard offset + queryLen <= totalLength else { return nil }

        var (pieceIdx, localOff) = findPieceAndLocalOffset(offset)
        var pos = offset
        var queryIdx = 0
        var matchStart = offset
        var matchPieceIdx = pieceIdx
        var matchLocalOff = localOff

        func currentByte() -> UInt8? {
            guard pieceIdx < pieces.count else { return nil }
            let piece = pieces[pieceIdx]
            guard localOff < piece.length else { return nil }
            return buffer(for: piece)[piece.start + localOff]
        }

        func advance() {
            pos += 1
            localOff += 1
            if pieceIdx < pieces.count && localOff >= pieces[pieceIdx].length {
                pieceIdx += 1
                localOff = 0
            }
        }

        while pos + queryLen - queryIdx <= totalLength {
            guard let ch = currentByte() else { break }
            if ch == queryBytes[queryIdx] {
                if queryIdx == 0 {
                    matchStart = pos
                    matchPieceIdx = pieceIdx
                    matchLocalOff = localOff
                }
                queryIdx += 1
                if queryIdx == queryLen { return matchStart }
                advance()
            } else if queryIdx > 0 {
                pieceIdx = matchPieceIdx
                localOff = matchLocalOff
                pos = matchStart
                queryIdx = 0
                advance()
            } else {
                advance()
            }
        }
        return nil
    }

    public func searchBackward(_ query: String, from offset: Int) -> Int? {
        guard !query.isEmpty else { return nil }
        let queryLen = query.utf8.count
        guard offset >= queryLen - 1 else { return nil }

        let chunkSize = 4096
        var end = min(offset + 1, totalLength)

        while end > 0 {
            let start = max(0, end - chunkSize)
            let text = getText(range: start..<end)
            if let range = text.range(of: query, options: [.backwards, .literal]) {
                return start + text[..<range.lowerBound].utf8.count
            }
            if start == 0 { break }
            end = start + queryLen
        }
        return nil
    }

    public func wordForward(from offset: Int) -> Int {
        var (pieceIdx, localOff) = findPieceAndLocalOffset(offset)
        var pos = offset

        func currentByte() -> UInt8? {
            guard pieceIdx < pieces.count else { return nil }
            let piece = pieces[pieceIdx]
            guard localOff < piece.length else { return nil }
            return buffer(for: piece)[piece.start + localOff]
        }

        func advance() {
            pos += 1
            localOff += 1
            if pieceIdx < pieces.count && localOff >= pieces[pieceIdx].length {
                pieceIdx += 1
                localOff = 0
            }
        }

        if let ch = currentByte(), isWordChar(ch) {
            while pos < totalLength {
                guard let ch = currentByte(), isWordChar(ch) else { break }
                advance()
            }
        }
        while pos < totalLength {
            guard let ch = currentByte(), !isWordChar(ch) else { break }
            advance()
        }
        return min(pos, max(totalLength - 1, 0))
    }

    public func wordBackward(from offset: Int) -> Int {
        let startPos = max(offset - 1, 0)
        var (pieceIdx, localOff) = findPieceAndLocalOffset(startPos)
        var pos = startPos

        func currentByte() -> UInt8? {
            guard pieceIdx < pieces.count else { return nil }
            let piece = pieces[pieceIdx]
            guard localOff < piece.length else { return nil }
            return buffer(for: piece)[piece.start + localOff]
        }

        func retreat() {
            if pos == 0 { return }
            pos -= 1
            if localOff > 0 {
                localOff -= 1
            } else if pieceIdx > 0 {
                pieceIdx -= 1
                localOff = pieces[pieceIdx].length - 1
            }
        }

        if let ch = currentByte(), !isWordChar(ch) {
            while pos > 0 {
                guard let ch = currentByte(), !isWordChar(ch) else { break }
                retreat()
            }
        }
        while pos > 0 {
            retreat()
            guard let ch = currentByte(), isWordChar(ch) else {
                if pos < startPos {
                    let (newPieceIdx, newLocalOff) = findPieceAndLocalOffset(pos + 1)
                    pieceIdx = newPieceIdx
                    localOff = newLocalOff
                }
                break
            }
        }
        return pos
    }

    private func isWordChar(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
        byte == UInt8(ascii: "_")
    }

    public func lineCharLength(line: Int) -> Int {
        getLineChars(line).count
    }

    public func getAllText() -> String {
        getText(range: 0..<totalLength)
    }
}
