import Foundation

enum EditorMode {
    case normal
    case insert
    case visual
    case visualLine
    case command
}

/// Per-file editor state. One tab == one EditorBuffer.
final class EditorBuffer {
    let buffer: PieceTable
    let filePath: String?
    var modified: Bool = false
    var mode: EditorMode = .normal
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var scrollX: Int = 0
    var scrollY: Int = 0
    var visualStartLine: Int = 0
    var visualStartCol: Int = 0
    var undoStack: [(offset: Int, deleted: String, inserted: String)] = []
    var redoStack: [(offset: Int, deleted: String, inserted: String)] = []
    var lspPendingChanges: [LSPTextChange] = []
    var semanticTokens: [SemanticToken] = []
    var markdownCache = SyntaxTokenizer.MarkdownCache()
    /// State of multi-line strings before each line; built lazily for the
    /// visible viewport, truncated on edits below the cursor.
    var mlStringStates: [SyntaxTokenizer.MultilineStringState] = []

    init(buffer: PieceTable, filePath: String? = nil) {
        self.buffer = buffer
        self.filePath = filePath
    }

    var displayName: String {
        guard let path = filePath, !path.isEmpty else { return "[No Name]" }
        return (path as NSString).lastPathComponent
    }
}

final class BufferManager {
    private(set) var buffers: [EditorBuffer] = []
    private(set) var activeIndex: Int = 0

    var active: EditorBuffer { buffers[activeIndex] }
    var count: Int { buffers.count }
    /// `:qa` guard — true when any tab has unsaved changes.
    var anyModified: Bool { buffers.contains { $0.modified } }

    init() {
        buffers.append(EditorBuffer(buffer: PieceTable(text: "")))
    }

    /// Resolves relative paths against the CWD and collapses `..`/`.` so that
    /// tab dedup and LSP uri matching are stable.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func buffer(forNormalizedPath path: String) -> EditorBuffer? {
        buffers.first { $0.filePath == path }
    }

    /// Opens a file in a new tab, or switches to the existing tab when the file
    /// is already open. The pristine `[No Name]` buffer created at startup is
    /// replaced by the first opened file instead of piling up as a tab.
    /// Returns the buffer and whether a new tab was created.
    @discardableResult
    func open(path: String) -> (buffer: EditorBuffer, isNew: Bool) {
        let normalized = Self.normalize(path)
        if let idx = buffers.firstIndex(where: { $0.filePath == normalized }) {
            activeIndex = idx
            return (buffers[idx], false)
        }
        let table = PieceTable.fromFile(path) ?? PieceTable(text: "")
        let tab = EditorBuffer(buffer: table, filePath: normalized.isEmpty ? nil : normalized)
        if buffers.count == 1, let only = buffers.first,
           only.filePath == nil, !only.modified, only.buffer.totalLength == 0 {
            buffers[0] = tab
            activeIndex = 0
        } else {
            buffers.append(tab)
            activeIndex = buffers.count - 1
        }
        return (tab, true)
    }

    enum CloseResult {
        case closed(EditorBuffer)
        case refusedModified
    }

    /// Closes the active tab. Keeps the invariant of at least one buffer by
    /// refilling with a fresh `[No Name]` when the last tab is closed.
    func closeActive(force: Bool) -> CloseResult {
        if active.modified && !force { return .refusedModified }
        let removed = active
        if buffers.count == 1 {
            buffers[0] = EditorBuffer(buffer: PieceTable(text: ""))
            activeIndex = 0
        } else {
            buffers.remove(at: activeIndex)
            if activeIndex >= buffers.count { activeIndex = buffers.count - 1 }
        }
        return .closed(removed)
    }

    /// `:e` semantics — replaces the content of the current tab. If the target
    /// file is already open in another tab, switches there instead (preserving
    /// the one-tab-per-file invariant). Returns the discarded buffer, or nil
    /// when a switch/refill happened.
    func replaceCurrent(path: String) -> EditorBuffer? {
        let normalized = Self.normalize(path)
        if let idx = buffers.firstIndex(where: { $0.filePath == normalized }) {
            activeIndex = idx
            return nil
        }
        let table = PieceTable.fromFile(path) ?? PieceTable(text: "")
        let fresh = EditorBuffer(buffer: table, filePath: normalized.isEmpty ? nil : normalized)
        let old = active
        buffers[activeIndex] = fresh
        return old
    }

    /// `gt` / `gT` — cycle active tab with wrap-around.
    func cycle(_ delta: Int) {
        guard buffers.count > 1 else { return }
        activeIndex = ((activeIndex + delta) % buffers.count + buffers.count) % buffers.count
    }

    /// Closes every tab except the active one and except tabs with unsaved
    /// changes. Returns the closed buffers (callers send LSP didClose) and
    /// how many modified tabs were kept.
    func closeOthers() -> (closed: [EditorBuffer], keptModified: Int) {
        let keep = active
        var closed = [EditorBuffer]()
        var kept = 0
        var remaining = [EditorBuffer]()
        for buf in buffers {
            if buf === keep {
                remaining.append(buf)
            } else if buf.modified {
                kept += 1
                remaining.append(buf)
            } else {
                closed.append(buf)
            }
        }
        guard closed.count > 0 else { return (closed, kept) }
        activeIndex = remaining.firstIndex { $0 === keep } ?? 0
        buffers = remaining
        return (closed, kept)
    }
}
