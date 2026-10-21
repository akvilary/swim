import Foundation
import SwimCore

/// Shared paint for unified-diff views: the line style map and the
/// row loop behind BOTH diff surfaces — the git panel's actionable
/// file diffs (`git diff`, hunk staging) and the git log window's
/// read-only commit diffs (`git show`). Only the PRESENTATION lives
/// here; what a diff MEANS (hunk surgery, reload-on-refresh clocks,
/// read-only-ness) stays with each owner — the two behaviors evolve
/// separately by design, so they share paint, not policy.
///
/// The panel's drawDiff kept its own copy of this loop until the git
/// log window needed the same rendering; the extraction is mechanical
/// (the panel's output must stay identical).
enum DiffStyle {
    /// One diff line's colors: metadata headers, added/removed
    /// content, hunk headers, and the dim default of context lines.
    static func lineStyle(for line: Substring) -> (fg: Color, bold: Bool) {
        if line.hasPrefix("commit ") { return (Theme.blue, true) }
        if line.hasPrefix("Author:") || line.hasPrefix("Date:") { return (Theme.cyan, false) }
        if line.hasPrefix("diff --git") { return (Theme.magenta, true) }
        if line.hasPrefix("index ")
            || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode")
            || line.hasPrefix("new mode") { return (Theme.comment, false) }
        if line.hasPrefix("+")  { return (Theme.green, false) }
        if line.hasPrefix("-")  { return (Theme.red, false) }
        if line.hasPrefix("@@") { return (Theme.cyan, false) }
        return (Theme.fgDark, false)
    }
}

extension Window {
    /// Draws the visible slice of a unified diff below the window's
    /// header plate (`contentTop`/`contentHeight`): per line, the
    /// editor-style gutter (green numbers on added lines, red on
    /// removed, dim elsewhere — `DiffGutter`, SwimCore) and the
    /// content colored by `DiffStyle`. The cursor row highlights;
    /// a `visualRange` (line-wise visual selection) overrides the
    /// background inside its span. Lines truncate at the window edge
    /// — neither diff surface scrolls horizontally.
    func drawDiffRows(
        diffLines: [Substring],
        gutter: [DiffGutter.Entry],
        gutterWidth: Int,
        scrollOffset: Int,
        cursorRow: Int,
        visualRange: ClosedRange<Int>?
    ) {
        let visibleLines = contentHeight
        let lnWidth = gutterWidth
        for i in 0..<visibleLines {
            let lineIdx = scrollOffset + i
            guard lineIdx < diffLines.count else { break }
            let line = diffLines[lineIdx]
            let row = i + contentTop
            let isCursor = lineIdx == cursorRow

            let style = DiffStyle.lineStyle(for: line)

            let bg: Color
            if let vr = visualRange, vr.contains(lineIdx) {
                bg = Theme.visualBg
            } else {
                bg = isCursor ? Theme.bgHighlight : Theme.bgDark
            }
            // The number color never changes with the cursor — the row
            // highlight already marks the current one.
            let entry = lineIdx < gutter.count ? gutter[lineIdx] : nil
            let numFg: Color
            if entry?.add == true {
                numFg = Theme.green
            } else if entry?.del == true {
                numFg = Theme.red
            } else {
                numFg = Theme.comment
            }
            drawLineNumberRow(row, number: entry?.num, lnWidth: lnWidth, fg: numFg, bg: bg)
            drawLine(String(line.prefix(max(0, width - lnWidth))), row: row, col: lnWidth, fg: style.fg, bg: bg, bold: style.bold)
        }
    }
}
