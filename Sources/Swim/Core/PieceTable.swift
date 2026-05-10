import Foundation

struct Piece {
    var start: Int
    var length: Int
    var isAdd: Bool

    var range: Range<Int> { start..<(start + length) }
}

final class PieceTable {
    private var original = [UInt8]()
    private var addBuffer = [UInt8]()
    private var pieces = [Piece]()
    private var lineStarts = [Int]()

    var totalLength: Int {
        pieces.reduce(0) { $0 + $1.length }
    }

    var lineCount: Int {
        lineStarts.count
    }

    init(text: String) {
        let data = [UInt8](text.utf8)
        original = data
        pieces = [Piece(start: 0, length: data.count, isAdd: false)]
        rebuildLineIndex()
    }

    init(data: [UInt8]) {
        original = data
        pieces = [Piece(start: 0, length: data.count, isAdd: false)]
        rebuildLineIndex()
    }

    static func fromFile(_ path: String) -> PieceTable? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return PieceTable(data: [UInt8](data))
    }

    private func buffer(for piece: Piece) -> [UInt8] {
        piece.isAdd ? addBuffer : original
    }

    private func rebuildLineIndex() {
        lineStarts = [0]
        var offset = 0
        for piece in pieces {
            let buf = buffer(for: piece)
            for i in 0..<piece.length {
                if buf[piece.start + i] == UInt8(ascii: "\n") {
                    lineStarts.append(offset + i + 1)
                }
            }
            offset += piece.length
        }
    }

    private func rebuildLineIndex(fromOffset startOffset: Int) {
        let startIdx = binarySearchLineIndex(startOffset)
        if lineStarts.count > startIdx {
            lineStarts.removeSubrange(startIdx...)
        }

        var offset = startOffset
        var pieceOffset = 0
        var foundStart = false

        for piece in pieces {
            let pieceEnd = pieceOffset + piece.length
            if !foundStart {
                if startOffset >= pieceEnd {
                    pieceOffset += piece.length
                    continue
                }
                foundStart = true
                let localStart = startOffset - pieceOffset
                let buf = buffer(for: piece)
                for i in localStart..<piece.length {
                    if buf[piece.start + i] == UInt8(ascii: "\n") {
                        lineStarts.append(offset + i - localStart + 1)
                    }
                }
                offset += piece.length - localStart
                pieceOffset += piece.length
                continue
            }
            let buf = buffer(for: piece)
            for i in 0..<piece.length {
                if buf[piece.start + i] == UInt8(ascii: "\n") {
                    lineStarts.append(offset + i + 1)
                }
            }
            offset += piece.length
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

    func lineStart(line: Int) -> Int {
        guard line >= 0 && line < lineStarts.count else { return 0 }
        return lineStarts[line]
    }

    func lineEnd(line: Int) -> Int {
        guard line >= 0 else { return 0 }
        if line + 1 < lineStarts.count { return lineStarts[line + 1] }
        return totalLength
    }

    func lineLength(line: Int) -> Int {
        lineEnd(line: line) - lineStart(line: line)
    }

    func offsetToLineCol(_ offset: Int) -> (line: Int, col: Int) {
        let idx = binarySearchLineIndex(offset) - 1
        let line = max(0, idx)
        let col = offset - lineStarts[line]
        return (line, col)
    }

    func insert(_ text: String, at offset: Int) {
        guard !text.isEmpty else { return }
        let data = [UInt8](text.utf8)
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

    func delete(at offset: Int, length: Int) {
        guard length > 0 else { return }
        var remaining = length
        var currentOffset = offset
        var removeRanges = [(start: Int, end: Int)]()

        while remaining > 0 {
            let (pieceIdx, localOffset) = findPieceAndLocalOffset(currentOffset)
            guard pieceIdx < pieces.count else { break }

            let piece = pieces[pieceIdx]
            let availableInPiece = piece.length - localOffset
            let deleteLen = min(remaining, availableInPiece)

            if localOffset == 0 && deleteLen == piece.length {
                removeRanges.append((pieceIdx, pieceIdx))
                currentOffset += deleteLen
                remaining -= deleteLen
            } else if localOffset == 0 {
                var p = piece
                p.start += deleteLen
                p.length -= deleteLen
                pieces[pieceIdx] = p
                currentOffset += deleteLen
                remaining -= deleteLen
            } else if deleteLen == availableInPiece {
                var p = piece
                p.length = localOffset
                pieces[pieceIdx] = p
                currentOffset += deleteLen
                remaining -= deleteLen
            } else {
                let before = Piece(start: piece.start, length: localOffset, isAdd: piece.isAdd)
                let after = Piece(start: piece.start + localOffset + deleteLen, length: piece.length - localOffset - deleteLen, isAdd: piece.isAdd)
                pieces.replaceSubrange(pieceIdx...pieceIdx, with: [before, after])
                currentOffset += deleteLen
                remaining -= deleteLen
            }
        }

        for (start, end) in removeRanges.reversed() {
            pieces.removeSubrange(start...end)
        }

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

    func getChar(at offset: Int) -> UInt8? {
        let (pieceIdx, localOffset) = findPieceAndLocalOffset(offset)
        guard pieceIdx < pieces.count else { return nil }
        let piece = pieces[pieceIdx]
        let buf = buffer(for: piece)
        guard localOffset < buf.count else { return nil }
        return buf[piece.start + localOffset]
    }

    func getText(range: Range<Int>) -> String {
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

    func getLine(_ lineNum: Int) -> String {
        guard lineNum >= 0 && lineNum < lineStarts.count else { return "" }
        let start = lineStarts[lineNum]
        let end = lineEnd(line: lineNum)
        let text = getText(range: start..<end)
        if text.hasSuffix("\r\n") { return String(text.dropLast(2)) }
        if text.hasSuffix("\n") { return String(text.dropLast()) }
        if text.hasSuffix("\r") { return String(text.dropLast()) }
        return text
    }

    func getLineData(_ lineNum: Int) -> [UInt8] {
        guard lineNum >= 0 && lineNum < lineStarts.count else { return [] }
        let start = lineStarts[lineNum]
        let end = lineEnd(line: lineNum)
        var result = [UInt8]()
        var accumulated = 0
        for piece in pieces {
            if accumulated >= end { break }
            let pieceEnd = accumulated + piece.length
            if pieceEnd <= start {
                accumulated += piece.length
                continue
            }
            let buf = buffer(for: piece)
            let localStart = max(0, start - accumulated)
            let localEnd = min(piece.length, end - accumulated)
            result.append(contentsOf: buf[piece.start + localStart..<piece.start + localEnd])
            accumulated += piece.length
        }
        if result.last == UInt8(ascii: "\n") { result.removeLast() }
        if result.last == UInt8(ascii: "\r") { result.removeLast() }
        return result
    }

    func getAllText() -> String {
        getText(range: 0..<totalLength)
    }

    func search(_ query: String, from offset: Int = 0) -> Int? {
        guard !query.isEmpty else { return nil }
        let queryBytes = [UInt8](query.utf8)
        var pos = offset
        var queryIdx = 0

        while pos < totalLength {
            let ch = getChar(at: pos)
            if ch == queryBytes[queryIdx] {
                queryIdx += 1
                if queryIdx == queryBytes.count { return pos - queryBytes.count + 1 }
            } else {
                if queryIdx > 0 {
                    pos -= queryIdx
                    queryIdx = 0
                }
            }
            pos += 1
        }
        return nil
    }

    func searchBackward(_ query: String, from offset: Int) -> Int? {
        guard !query.isEmpty else { return nil }
        let queryBytes = [UInt8](query.utf8)
        guard offset >= queryBytes.count - 1 else { return nil }
        var pos = offset - queryBytes.count + 1
        while pos >= 0 {
            var match = true
            for i in 0..<queryBytes.count {
                if getChar(at: pos + i) != queryBytes[i] {
                    match = false
                    break
                }
            }
            if match { return pos }
            pos -= 1
        }
        return nil
    }

    func wordForward(from offset: Int) -> Int {
        var pos = offset
        let total = totalLength
        var ch = getChar(at: pos)
        if ch != nil && isWordChar(ch!) {
            while pos < total {
                ch = getChar(at: pos)
                if ch == nil || !isWordChar(ch!) { break }
                pos += 1
            }
        }
        while pos < total {
            ch = getChar(at: pos)
            if ch == nil || isWordChar(ch!) { break }
            pos += 1
        }
        return min(pos, max(total - 1, 0))
    }

    func wordBackward(from offset: Int) -> Int {
        var pos = max(offset - 1, 0)
        var ch = getChar(at: pos)
        if ch != nil && !isWordChar(ch!) {
            while pos > 0 {
                ch = getChar(at: pos)
                if ch == nil || isWordChar(ch!) { break }
                pos -= 1
            }
        }
        while pos > 0 {
            ch = getChar(at: pos - 1)
            if ch == nil || !isWordChar(ch!) { break }
            pos -= 1
        }
        return pos
    }

    private func isWordChar(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
        byte == UInt8(ascii: "_")
    }
}
