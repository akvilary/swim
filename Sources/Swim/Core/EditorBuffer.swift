import SwimCore
import Foundation

/// Line-level git status of one file, computed in the background by the
/// Application (`git diff --unified=0` against the index and `--cached`
/// against HEAD): `unstaged` — lines changed in the working tree
/// (orange numbers), `staged` — lines changed in the index only
/// (stagedColor; a staged add covers the whole file), `isNewFile` — the
/// file is untracked (`??`), so every line counts as added (green).
/// Indices are 0-based, of the on-disk content the diff was computed
/// against.
struct GitLineStatus {
    var isNewFile = false
    var staged: Set<Int> = []
    var unstaged: Set<Int> = []
}

/// Disk-file fingerprint: what vim remembers per buffer (mtime + size;
/// vim also tracks mode, which swim doesn't need — it serves vim's
/// readonly detection, not freshness). A cheap PRE-filter for "the file
/// changed" — the final arbiter is the content comparison in
/// `BufferManager.reload`, so a false positive (a bare `touch`) is
/// harmless: the file is re-read, found equal, and only the stamp moves.
/// Consistent with PreviewWindow/SearchResults, which fingerprint the
/// same way. One `attributesOfItem` call produces both fields.
struct FileStamp: Equatable {
    var mtime: TimeInterval
    var size: Int
}

/// Per-file editor state. One tab == one EditorBuffer.
final class EditorBuffer {
    let buffer: PieceTable
    let filePath: String?
    var modified: Bool = false
    var mode: WindowMode = .normal
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    /// Sticky desired column in DISPLAY CELLS (vim curswant): survives
    /// vertical moves across shorter lines and mode switches; each
    /// vertical move resolves it into a grapheme via
    /// charIndex(atDisplayCol:) — the per-line tab layout cannot shift
    /// the wanted screen column. In visual-block the same value IS the
    /// cursor corner (visualBlockCol), so Ctrl+V → v → Ctrl+V keeps the
    /// virtual column exactly, mid-tab included.
    var desiredCol: Int = 0
    var scrollX: Int = 0
    var scrollY: Int = 0
    var visualStartLine: Int = 0
    var visualStartCol: Int = 0
    /// Virtual visual-block column (display cells, see
    /// SwimCore/VisualBlock): the cursor's right/left corner, NOT clamped
    /// to the line length — only in `.visualBlock`; outside it it is dead
    /// and is re-initialized on the next entry.
    var visualBlockCol: Int = 0
    var undoStack: [(offset: Int, deleted: String, inserted: String)] = []
    var redoStack: [(offset: Int, deleted: String, inserted: String)] = []
    var lspPendingChanges: [LSPTextChange] = []
    var semanticTokens: [SemanticToken] = []
    var diagnostics: [LSPDiagnostic] = []
    var markdownCache = MarkdownTokenizer.Cache()
    /// State of multi-line strings before each line; built lazily for the
    /// visible viewport, truncated from the edited line onward (the edit's
    /// own line — NOT the cursor line: undo/redo can edit far from it).
    var mlStringStates: [SyntaxTokenizer.MultilineStringState] = []
    /// File fingerprint (mtime+size) as of the last load/save — the
    /// external-change sweep compares against it to detect disk rewrites
    /// (a git pull merge, a command run in the embedded terminal, an
    /// external agent — see ADR 0001). Nil = unknown (the file could not
    /// be stated at open). The pre-write guard in `saveOrConfirm` reads
    /// it too; nil on disk SKIPS the guard, so `:w` recreates a deleted
    /// file — vim semantics.
    var fileStamp: FileStamp? = nil
    /// Line-level git status for the gutter number coloring (nil — not
    /// fetched / not in a repository). Stored per tab so it survives tab
    /// switches; refreshed by the background fetch each time the file is
    /// saved, opened or the worktree changes through the git panel.
    var gitStatus: GitLineStatus?

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

    /// File fingerprint (mtime+size), or nil when the file cannot be
    /// stated (missing/unreadable).
    static func fileStamp(of path: String) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else { return nil }
        return FileStamp(mtime: date.timeIntervalSince1970, size: size.intValue)
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
        tab.fileStamp = normalized.isEmpty ? nil : Self.fileStamp(of: normalized)
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

    /// Reloads the tab for `path` from disk when its buffer is clean —
    /// an external tool (a git discard from the panel) rewrote the file.
    /// The tab keeps its place, mode and clamped cursor/scroll; the undo
    /// history resets (the old content is gone). A modified buffer is
    /// left untouched — unsaved edits outrank the disk — and so is a
    /// file that no longer exists on disk (vim semantics: the in-memory
    /// copy survives, `:w` would recreate it). A rewrite that produced
    /// identical content only refreshes the mtime (no swap — the undo
    /// history must not be reset for nothing). Returns the fresh buffer
    /// when a reload happened, nil otherwise.
    @discardableResult
    func reloadIfClean(path: String) -> EditorBuffer? {
        reload(path: path, force: false)
    }

    /// `:e!`-style forced reload — the [R]eload answer of the
    /// changed-on-disk confirm prompt: the user deliberately discards
    /// their edits. No identical-content guard either: the point is to
    /// reset the modified flag.
    @discardableResult
    func reloadDiscardingEdits(path: String) -> EditorBuffer? {
        reload(path: path, force: true)
    }

    private func reload(path: String, force: Bool) -> EditorBuffer? {
        let normalized = Self.normalize(path)
        guard let idx = buffers.firstIndex(where: { $0.filePath == normalized }) else { return nil }
        let tab = buffers[idx]
        guard force || !tab.modified, let table = PieceTable.fromFile(normalized) else { return nil }
        let newStamp = Self.fileStamp(of: normalized)
        if !force, tab.buffer.getAllText() == table.getAllText() {
            tab.fileStamp = newStamp
            return nil
        }
        let fresh = EditorBuffer(buffer: table, filePath: normalized)
        fresh.fileStamp = newStamp
        fresh.mode = tab.mode
        let lastLine = max(0, table.lineCount - 1)
        fresh.cursorLine = min(tab.cursorLine, lastLine)
        fresh.cursorCol = min(tab.cursorCol, max(0, table.lineCharLength(line: fresh.cursorLine)))
        fresh.desiredCol = tab.desiredCol
        // The visual selection anchor rides with the mode: a reload in a
        // visual mode must not reset the anchor to the origin (a phantom
        // selection spanning from the file start), it clamps to the new
        // geometry like the cursor does.
        fresh.visualStartLine = min(tab.visualStartLine, lastLine)
        fresh.visualStartCol = min(tab.visualStartCol, max(0, table.lineCharLength(line: fresh.visualStartLine)))
        fresh.visualBlockCol = tab.visualBlockCol
        fresh.scrollY = min(tab.scrollY, lastLine)
        fresh.scrollX = tab.scrollX
        buffers[idx] = fresh
        return fresh
    }

    /// After a command that may have rewritten working files through git
    /// (a pull merge, anything run in the embedded terminal), or on any
    /// arrival trigger (focus events, internal focus landing on the
    /// editor — ADR 0001): reload every clean tab whose file changed on
    /// disk (fingerprint differs). Modified tabs keep the user's edits;
    /// files gone from disk keep their buffers (vim semantics). The
    /// `skipping` tab is exempt: the changed-on-disk write confirm and
    /// the `:s//c` confirm session hold pending byte offsets against
    /// their exact instance — a swap underneath would corrupt them
    /// (non-active tabs reload freely; the skipped tab is caught by the
    /// next trigger after the session ends).
    func reloadChangedOnDisk(skipping: EditorBuffer? = nil) -> [EditorBuffer] {
        var reloaded = [EditorBuffer]()
        // Iterating a copy (Array value semantics): reloadIfClean swaps
        // elements in `buffers` mid-loop safely.
        for tab in buffers where !tab.modified && tab !== skipping {
            guard let path = tab.filePath,
                  let diskStamp = Self.fileStamp(of: path),
                  diskStamp != tab.fileStamp,
                  let fresh = reloadIfClean(path: path) else { continue }
            reloaded.append(fresh)
        }
        return reloaded
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
        fresh.fileStamp = normalized.isEmpty ? nil : Self.fileStamp(of: normalized)
        let old = active
        buffers[activeIndex] = fresh
        return old
    }

    /// The file was just written by `:w` — record its fingerprint so the
    /// external-change sweep doesn't flag our own save.
    func noteSaved() {
        if let path = active.filePath { active.fileStamp = Self.fileStamp(of: path) }
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
