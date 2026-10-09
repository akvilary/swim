import Foundation

/// Interaction modes. Each window declares the modes it supports via
/// `availableModes`; the mode determines what `:` does, how Tab behaves
/// and what the status bar shows:
/// - `menu` — the standard behavior of the list windows (git panel,
///   explorer, search results): j/k line navigation, Enter performs the
///   primary action, other action keys are window-specific extras.
/// - `normal`, `insert`, `visual`, `visualLine` — editor modes; menu
///   windows reuse `visualLine` for line selection.
/// - `command` — the command line owned by the window that entered it:
///   `:q`/`:q!` close that window, an editor's `:w` saves it.
enum WindowMode {
    case menu
    case normal
    case insert
    case visual
    case visualLine
    case command
}

/// A one-line plate drawn at the top of a window (row 0); window content
/// then starts at `contentTop`. Set `window.headerPlate` and call
/// `drawPlate()` from `update()` to use it.
struct HeaderPlate {
    var text: String
    var fg: Color = Theme.fg
    var bg: Color = Theme.bgHighlight
}

class Window {
    weak var delegate: WindowDelegate?
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var height: Int = 0
    var visible: Bool = false
    var focused: Bool = false
    var dirty: Bool = true

    private var cells: [Cell]

    private var _mode: WindowMode = .menu

    /// The window's current mode. Stored on the window itself; editors
    /// override this to keep the mode per tab.
    var mode: WindowMode {
        get { _mode }
        set { _mode = newValue }
    }

    /// Modes this window can be in. Windows that list `.command` own a
    /// command line when focused; windows without it (terminal, passive
    /// panels) never do — `:` is literal text there.
    var availableModes: [WindowMode] { [] }

    /// The command-line buffer while this window owns the command line.
    var commandBuffer: String = ""
    /// Caret position (in Characters) inside `commandBuffer` — rendered
    /// inverted in the status bar; arrows/Home/End/Delete edit around it.
    var commandCursorPos: Int = 0

    /// Optional one-line plate at the top of the window. Windows that
    /// show it draw their content starting at `contentTop`.
    var headerPlate: HeaderPlate?

    /// Row where window content starts — below the header plate when one
    /// is shown.
    var contentTop: Int { headerPlate == nil ? 0 : 1 }

    /// Number of content rows below the plate.
    var contentHeight: Int { max(0, height - contentTop) }

    /// Draws the plate row; call from update() after assigning
    /// headerPlate (it may change per frame).
    func drawPlate() {
        guard let plate = headerPlate else { return }
        drawHeader(plate.text, fg: plate.fg, bg: plate.bg)
    }

    func enterCommandMode(prefill: String = "") {
        commandBuffer = prefill
        commandCursorPos = prefill.count
        mode = .command
        dirty = true
    }

    func exitCommandMode() {
        guard mode == .command else { return }
        mode = availableModes.contains(.menu) ? .menu : .normal
        commandBuffer = ""
        commandCursorPos = 0
        dirty = true
    }

    /// Command-mode key handling shared by every mode-capable window:
    /// the buffer is typed through the status bar with a visible caret
    /// (arrows/Home/End move it, Delete removes forward), Enter executes
    /// the command against this window, Esc cancels.
    func handleCommandModeKey(_ key: Key) -> Bool {
        switch key {
        case .escape:
            exitCommandMode()
        case .enter:
            let cmd = commandBuffer
            // Exit before executing: a command like `:q` closes this very
            // window and must not leave it in command mode.
            exitCommandMode()
            executeCommand(cmd)
        case .left:
            if commandCursorPos > 0 { commandCursorPos -= 1 }
        case .right:
            if commandCursorPos < commandBuffer.count { commandCursorPos += 1 }
        case .home:
            commandCursorPos = 0
        case .end:
            commandCursorPos = commandBuffer.count
        case .backspace:
            if commandCursorPos > 0 {
                let idx = commandBuffer.index(commandBuffer.startIndex, offsetBy: commandCursorPos - 1)
                commandBuffer.remove(at: idx)
                commandCursorPos -= 1
            } else if commandBuffer.isEmpty {
                exitCommandMode()
            }
        case .delete:
            if commandCursorPos < commandBuffer.count {
                let idx = commandBuffer.index(commandBuffer.startIndex, offsetBy: commandCursorPos)
                commandBuffer.remove(at: idx)
            }
        case .char(let c):
            let idx = commandBuffer.index(commandBuffer.startIndex, offsetBy: commandCursorPos)
            commandBuffer.insert(c, at: idx)
            commandCursorPos += 1
        case .paste(let text):
            guard let flat = Self.pasteFlatLine(text) else { return false }
            let idx = commandBuffer.index(commandBuffer.startIndex, offsetBy: commandCursorPos)
            commandBuffer.insert(contentsOf: flat, at: idx)
            commandCursorPos += flat.count
        default:
            return false
        }
        return true
    }

    /// Paste text for a single-line surface (the command line, filters,
    /// prompts): newlines are dropped (vim cmdline parity — a pasted
    /// command must not execute itself), tabs become one space —
    /// "git<TAB>status" stays two words, not glued. No language policy
    /// exists here, so one tab is one space, not an indent step. The CR
    /// check is defense-in-depth: the paste payload is already
    /// newline-normalized at the parse layer.
    static func pasteFlatLine(_ text: String) -> String? {
        var flat = ""
        flat.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\n", "\r": continue
            case "\t": flat.append(" ")
            default: flat.append(ch)
            }
        }
        return flat.isEmpty ? nil : flat
    }

    /// Optional replacement for the status-bar COMMAND label while this
    /// window owns the command line — e.g. the command window collecting
    /// a credential shows LOGIN / PASSWORD instead. Nil — the standard
    /// COMMAND label. A non-nil value also drops the ":" prefix: the
    /// surface is a credential input, not a ":" command.
    func commandModeLabel() -> String? { nil }

    /// What a key did to a single-line typing surface's (text, caret).
    enum LineEditOutcome {
        /// The key owns no editing meaning here.
        case notEditing
        /// Only the caret moved — the text is intact, so a surface that
        /// re-queries on edits (the branch filter) owes no re-query.
        case caretOnly
        /// The text mutated.
        case textChanged
    }

    /// The single key→edit mapping for the windows' own single-line
    /// typing surfaces — the branch picker's filter and new-branch
    /// name, the search query, the terminal prompt. One place keeps
    /// the editing semantics, so the surfaces can never drift apart.
    /// Pure: no window state, no side effects; what an edit MEANS
    /// (re-query git, restart a search, scroll to the prompt) stays
    /// with the caller. Backspace and Delete always report
    /// .textChanged even when there was nothing to remove — a no-op
    /// edit is still an edit key. Multi-scalar characters are
    /// rejected: they are not typing input for these surfaces (emoji
    /// have no place in a query or a branch name).
    ///
    /// The command line (`handleCommandModeKey`) deliberately keeps
    /// its own arm: its contract differs — every character inserts
    /// (no single-scalar guard), backspace on an empty buffer EXITS
    /// the mode, and Enter/Esc are intercepted before any editing.
    static func applyLineEdit(_ key: Key, text: inout String, cursor: inout Int) -> LineEditOutcome {
        switch key {
        case .backspace:
            if cursor > 0 {
                let idx = text.index(text.startIndex, offsetBy: cursor - 1)
                text.remove(at: idx)
                cursor -= 1
            }
            return .textChanged
        case .delete:
            if cursor < text.count {
                let idx = text.index(text.startIndex, offsetBy: cursor)
                text.remove(at: idx)
            }
            return .textChanged
        case .left:
            if cursor > 0 { cursor -= 1 }
            return .caretOnly
        case .right:
            if cursor < text.count { cursor += 1 }
            return .caretOnly
        case .home:
            cursor = 0
            return .caretOnly
        case .end:
            cursor = text.count
            return .caretOnly
        case .char(let c) where c.unicodeScalars.count == 1:
            let idx = text.index(text.startIndex, offsetBy: cursor)
            text.insert(c, at: idx)
            cursor += 1
            return .textChanged
        case .paste(let pasted):
            // Unlike typed chars, paste keeps multi-scalar characters
            // (emoji): it is bulk text from another source, not a
            // keystroke aimed at the surface.
            guard let flat = Self.pasteFlatLine(pasted) else { return .notEditing }
            let idx = text.index(text.startIndex, offsetBy: cursor)
            text.insert(contentsOf: flat, at: idx)
            cursor += flat.count
            return .textChanged
        default:
            return .notEditing
        }
    }

    /// Whether the command line displays its content masked — one
    /// asterisk per character, the same length, so the caret position
    /// stays exact. The buffer itself keeps the real text (editing and
    /// submit work unchanged); only the status-bar rendering masks.
    func masksCommandLine() -> Bool { false }

    /// Executes a command typed in this window's command line. The base
    /// implementation covers the window-management commands shared by
    /// every window; editors override it to add file commands.
    @discardableResult
    func executeCommand(_ cmd: String) -> Bool {
        switch cmd {
        case "q", "quit", "bd", "q!", "quit!", "forcequit", "bd!",
             "qa", "qa!", "terminal", "term", "sh":
            delegate?.handleEditorCommand(cmd)
            return true
        default:
            return false
        }
    }

    init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cells = Array(repeating: .blank, count: width * height)
    }

    func resize(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        // Zero is legitimate: a squeezed-out window (the layout gave its
        // rows to the panels) draws nothing — every cell/draw/caret path
        // is bounds-guarded. Never negative.
        self.width = max(0, width)
        self.height = max(0, height)
        self.cells = Array(repeating: .blank, count: self.width * self.height)
        self.dirty = true
    }

    func setCell(_ row: Int, _ col: Int, _ cell: Cell) {
        guard row >= 0 && row < height && col >= 0 && col < width else { return }
        let idx = row * width + col
        if cells[idx] != cell {
            cells[idx] = cell
            dirty = true
        }
    }

    func getCell(_ row: Int, _ col: Int) -> Cell {
        guard row >= 0 && row < height && col >= 0 && col < width else { return .blank }
        return cells[row * width + col]
    }

    func fillRegion(row: Int, col: Int, width w: Int, height h: Int, cell: Cell) {
        let rStart = max(0, row)
        let rEnd = min(row + h, height)
        let cStart = max(0, col)
        let cEnd = min(col + w, width)
        guard rStart < rEnd && cStart < cEnd else { return }

        let fillWidth = cEnd - cStart
        let fillCells = Array(repeating: cell, count: fillWidth)
        for r in rStart..<rEnd {
            let base = r * width + cStart
            cells.replaceSubrange(base..<(base + fillWidth), with: fillCells)
        }
        dirty = true
    }

    func writeString(_ str: String, row: Int, col: Int, fg: Color = .default, bg: Color = .default, bold: Bool = false) {
        var c = col
        for char in str {
            guard c < width && row >= 0 && row < height else { break }
            if char == "\t" {
                let spaces = 4 - (c % 4)
                for _ in 0..<spaces {
                    guard c < width else { break }
                    setCell(row, c, Cell.colored(" ", fg: fg, bg: bg, bold: bold))
                    c += 1
                }
            } else {
                // Wide graphemes (CJK, emoji) occupy two cells: the
                // right one is the continuation the renderer skips
                // (the wide char itself advances the terminal cursor
                // by two). A glyph that would straddle the right edge
                // is dropped whole — no sliced wide char. Zero-width
                // and control characters render as one blank cell,
                // matching the InputLine window math (max(1, width)).
                let w = max(1, char.displayWidth)
                guard c + w <= width else { break }
                setCell(row, c, Cell.colored(char, fg: fg, bg: bg, bold: bold))
                if w == 2 {
                    var cont = Cell.colored(" ", fg: fg, bg: bg, bold: bold)
                    cont.wideContinuation = true
                    setCell(row, c + 1, cont)
                }
                c += w
            }
        }
    }

    func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
        guard row >= 0 && row < height else { return }
        writeString(text, row: row, col: col, fg: fg, bg: bg, bold: bold)
    }

    /// One line-number gutter row in the editor style: the number
    /// right-aligned within the first `lnWidth - 1` cells and one
    /// trailing slot — a plain space, or the caller's mark (the editor's
    /// diagnostic circles). Nil number — the blank gutter. The shared
    /// painting primitive behind the editor gutter and the git-diff
    /// gutter, so both look identical; callers own the width, the row
    /// and the colors (a mark carries its own fg/bg — e.g. the stacked
    /// two-color error+warning cell paints its bottom half through bg).
    func drawLineNumberRow(_ row: Int, number: Int?, lnWidth: Int, fg: Color, bg: Color,
                           mark: (char: Character, fg: Color, bg: Color)? = nil) {
        guard row >= 0 && row < height else { return }
        if let number {
            let numStr = String(number)
            let padded = String(repeating: " ", count: max(0, lnWidth - numStr.count - 1)) + numStr
            for (i, c) in padded.enumerated() where i < lnWidth - 1 {
                setCell(row, i, Cell.colored(c, fg: fg, bg: bg))
            }
        } else {
            for i in 0..<min(lnWidth - 1, width) {
                setCell(row, i, Cell.colored(" ", fg: fg, bg: bg))
            }
        }
        guard lnWidth >= 1, lnWidth - 1 < width else { return }
        if let mark {
            setCell(row, lnWidth - 1, Cell.colored(mark.char, fg: mark.fg, bg: mark.bg))
        } else {
            setCell(row, lnWidth - 1, Cell.colored(" ", fg: fg, bg: bg))
        }
    }

    func clear(bg: Color = Theme.bgDark) {
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: bg))
    }

    func drawHeader(_ text: String, fg: Color, bg: Color = Theme.bgHighlight, bold: Bool = true) {
        // The header may be longer than the window (e.g. a long diff path) —
        // truncate instead of building an inverted range.
        let visible = text.prefix(width)
        for (i, c) in visible.enumerated() {
            setCell(0, i, Cell.colored(c, fg: fg, bg: bg, bold: bold))
        }
        for i in visible.count..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: bg))
        }
    }

    func handleKey(_ key: Key) -> Bool { false }

    /// The terminal cursor this window wants shown — its typing surface:
    /// the insert-mode caret in an editor, the command-line caret in the
    /// status bar (same bar shape — command mode is an insert surface
    /// there, Enter being the only intercepted key). Nil — no typing
    /// surface; by focus rules at most one visible window returns non-nil.
    func cursorRenderInfo() -> CursorRenderInfo? { nil }

    func update() {}

    func poll() {}

    static func clampedScroll(selectedIndex: Int, scrollOffset: Int, visibleCount: Int) -> Int {
        if selectedIndex < scrollOffset { return selectedIndex }
        if selectedIndex >= scrollOffset + visibleCount { return selectedIndex - visibleCount + 1 }
        return scrollOffset
    }
}
