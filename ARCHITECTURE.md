# Swim — Terminal Text Editor in Swift

## Overview

Swim is a vim-like terminal text editor written in pure Swift with no external dependencies. It runs on Linux and macOS. It uses the Tokyo Night Storm theme, a Piece Table data structure, a built-in file explorer, a git panel (stage/unstage/discard/commit), project-wide search, a window stack (focus = top of the stack, closing = pop), a unified window mode model (menu/insert/normal/visual/visualLine/visualBlock/command — the command line belongs to the owning window), and LSP semantic highlighting.

---

## Architecture

```
main.swift
  └── Application (orchestrator, implements WindowDelegate)
        ├── Terminal.shared (low-level I/O)
        ├── Key.parse() (input parsing)
        ├── Spaces (window spaces: editor, search)
        ├── LayoutManager (window rectangle calculation)
        ├── Renderer (diff-based terminal output)
        ├── windowStack (z-order of open windows; top = focused)
        ├── EditorWindow (main editor)
        │     ├── PieceTable (text buffer)
        │     ├── SyntaxTokenizer.tokenize (syntax layer: keywords/strings/numbers)
        │     ├── SyntaxTokenizer.mergeWithLSP (layered merge: LSP on top of builtin)
        │     ├── MarkdownTokenizer (viewport Markdown highlighting with an incremental cache)
        │     └── SemanticToken[] (LSP highlighting converted to grapheme indices)
        ├── CommitWindow (commit message editor — a thin layer over EditorWindow)
        ├── FileExplorerWindow (file tree)
        ├── GitPanelWindow (git status/commits/diff/commit)
        ├── SearchResultsWindow + PreviewWindow (project-wide search)
        ├── CommandWindow (output of long-running git commands)
        ├── TerminalWindow (built-in terminal)
        ├── StatusBarWindow (mode/position/command line)
        └── LSPClient (semantic tokens via sourcekit-lsp)
```

### Data Flows

**Input:** `Terminal.readByte()` → `Key.parse()` → `Application.handleGlobalKey()` → `Window.handleKey()`

**Editing:** `EditorWindow.handleKey()` → `PieceTable.insert/delete` → buffer modified → `dirty = true`

**Rendering:** `Window.update()` fills the cell buffer → `Renderer` compares with the previous frame → `Terminal` sends ANSI escapes → `flush()` to stdout

**Syntax highlighting:** `SyntaxTokenizer.tokenize()` always provides the syntax layer (keywords/strings/numbers), and when LSP tokens are present `mergeWithLSP` lays them on top (builtin fills the gaps; strings absorb nested LSP interpolation tokens) → `EditorWindow.semanticTokens` → mapping to colors via `Theme`; server diagnostics (`publishDiagnostics`) — gutter/underline/status bar (see LSPClient)

**Inter-window communication:** windows send events to `Application` through the `WindowDelegate` protocol (`openFile`, `openFileAtLine`, `handleEditorCommand`, `runGitCommand`, `gitCommandFinished`, `terminalCommandFinished`, `requestCommitMessage`, `requestCommit`, `reportError`, `requestRender`, `updatePreview`, `bufferClosed`, `fileSaved`, `gitWorktreeChanged`, `fileChangedOnDisk`, `reloadActiveBufferDiscardingEdits`, `activeFileChanged`, `requestClose`, `requestGoToDefinition`, `requestGoBack`)

---

## File Structure

```
Sources/SwimCore/                       — Library target: pure dependency-free modules (available to unit tests)
├── PieceTable.swift                    — Text buffer data structure (tested by Tests/SwimCoreTests)
├── DiffGutter.swift                    — Parser for diff gutter line numbers (unified diff counters; tested by Tests/SwimCoreTests)
├── HunkLines.swift                     — Parser for unified diff -u0 hunk line ranges (new line numbers for the editor's git gutter; tested by Tests/SwimCoreTests)
├── Porcelain.swift                     — Parser for `status --porcelain -z` (NUL-separated fields, rename/copy orig) + GitChangeClass classification (shared by the git panel and decorations; tested)
├── BranchList.swift                    — Parser for the branch picker's `for-each-ref` listing (NUL-separated fields, remote flag, remote HEAD symlink exclusion; request patterns: empty — local only, non-empty — heads+remotes; tested)
├── AppLocale.swift                     — Application locale: the single source of the system message language (git output, LSP handshake, child env; a value, immutable for the process lifetime; tested)
├── Locked.swift                        — Synchronous cross-thread mailbox slot: the value is reachable only through withLock; unlocked paths do not exist by construction
├── BackgroundTask.swift                — Restartable single-slot mailbox for background results: newest-wins — an in-flight request never races, the queue collapses to the latest one (prevents a late completion of an old task from clobbering a fresh result; tested)
├── StatusListSelection.swift           — Position retention policy when rebuilding a sectioned list (the git panel's selection and visual anchor follow the record within its section and keep the row when the record goes away; tested)
├── InputLine.swift                     — Horizontal scrolling policy for a single-line input surface, in terminal CELLS (tail at rest, the window shifts only when the caret leaves it; a wide grapheme is never cut at the edge; shared picture and caret column; tested)
├── CharWidth.swift                     — Grapheme width in terminal cells (0/1/2: zero-width/regular/wide CJK-emoji; Unicode East Asian Width table + binary search; the single authority for the renderer, panels, and input scrolling; `displayStep(atDisplayCol:tabWidth:)` — column step with tab expansion, also consumed by VisualBlock; tested)
├── BracketedPaste.swift                — Incremental scanner for bracketed paste payloads (byte-by-byte up to `ESC[201~`; content that merely looks like the marker is not swallowed; CR/CRLF → `\n` at a single point; tested)
├── MultilineInsert.swift               — Cursor after a multi-line bulk paste: lines down + graphemes on the last line (unified math for all editor paste paths; line breaks are counted by scalars — CRLF is one grapheme in Swift and a Character comparison skips it; tested)
├── NormalPending.swift                 — Accumulator for the pending normal-mode sequence, vim grammar `[count1] operator [count2] motion`: count before the operator (3dd) and after it (d3d, multiplied — 2d3d = 6), operators d/y/c, the g-prefix in a separate slot (dgg does not displace the operator), a bare 0 after an operator is the d0 motion; the discipline "arming either kept the sequence, or the defer killed it" + resetting interceptions outside handleNormal (interruptPending/enterCommandMode — the `d : Esc d`→dd leak class; tested)
├── NormalMotion.swift                  — Normal-mode motions by vim category (exclusive w/b/0/h/l — dl = x; inclusive e/$; linewise j/k/gg/G): resolution from position+count (nil — defaults G last/1G first) and operator-range normalization — sorting of backward-going ranges (db/dgg), the "exclusive end in column 0 → end of the previous line" adjustment (dw across a line break keeps it, db at BOL does not glue lines, :h exclusive rule 1); clamping line indices to lineStart/lineEnd (out of range those silently give 0/totalLength); tested
├── VisualBlock.swift                   — Visual-block math: display columns ↔ graphemes, line slices, reassembly with padding, Span (width ≥ 1 / insertion point); a single membership rule for highlighting/yank/edits; tested
├── TabPolicy.swift                     — Tab policy for incoming text: one tab = one language indent step in spaces (the same width as auto-indent and H/L; no tabs — untouched; tested)
├── Substitute.swift                    — vim-style `:s/pat/rep/[gic]`: command-line parsing (any prefix of "substitute", any vim-legal separator, backslash-escaped fields, the selection marks `'<`/`'>`/`'<,'>`), the bidirectional vim-magic↔ICU pattern translation (`\(` is a group, a bare `(` is a literal — ICU is exactly the other way around; bracket classes pass through; magic-mode prefixes rejected), replacement segments (`\0`–`\9`, `&`, `\r` = a line break), and the edit plan in the Piece Table's BYTE coordinates (ICU matches arrive in UTF-16 — the one conversion point; optional per-line byte windows restrict a blockwise `'<,'>s` to the rectangle; tested)
├── SyntaxTokenizer.swift              — Built-in syntax highlighting + `mergeWithLSP` (builtin tokens as a layer under LSP; tested)
├── MarkdownTokenizer.swift           — Markdown highlighting with a viewport cache (incremental scan of fenced blocks; tested)
├── SemanticToken.swift               — Shared value types of the LSP protocol (`SemanticToken`, `LSPTextChange`, `LSPDiagnostic`, `LSPDefinition`; Sendable)
├── SearchTree.swift                  — Results tree of the project search: `SearchResult` (path, line, match span) + the builder rooted at the working directory — one node per path component, the full chain root → … → dir → file → lines (dictionary-indexed build, subtree counts folded; tested)
├── TreeListNavigation.swift          — Navigation policy for a flattened tree list, shared by the explorer and the search results: the collapse target of the explorer-style `h` (the selected row's parent branch — the nearest row above one depth shallower, or itself at the top level; flatten-order invariant proven in the doc comment) and the first-child descend of Enter/`l` (the row right below, one depth deeper; tested)
├── Highlight.swift                   — Preview highlighting session: an immutable file's visible window behind one door — language routing (code/JSON/markdown by extension), viewport-scoped tokenization (visible lines only, on demand — nothing pre-colored), the extend-only string-state ladder (the content never changes, so it never invalidates), the markdown viewport cache, and the editor's ≥50000-line guard; the PieceTable is sealed inside (read surface only) — the caches' eternal validity rests on that immutability; tested

Sources/Swim/                           — Executable target (depends on SwimCore)
├── main.swift                    — Entry point
├── App/
│   ├── Application.swift         — Main controller (window stack, focus, closing)
│   ├── Spaces.swift              — Window spaces (editor, search)
│   ├── LayoutManager.swift       — Window rectangle calculation
│   ├── Renderer.swift            — Diff-based rendering to the terminal
│   └── WindowDelegate.swift      — Window events protocol → Application
├── Core/
│   ├── Cell.swift                — Screen cell + color
│   ├── Theme.swift               — Tokyo Night Storm palette
│   ├── Terminal.swift            — Low-level terminal I/O
│   ├── EditorBuffer.swift        — State of a single buffer + BufferManager (tabs)
│   ├── Input.swift               — Key parsing
│   ├── Shell.swift               — Launching subprocesses (git, which)
│   ├── PipeWriter.swift          — EPIPE-tolerant write(2) to child pipes (LSP frames, Shell stdin, InteractiveShell FIFO)
│   ├── InteractiveShell.swift    — Interactive subprocess + pull/push credential prompts (askpass FIFO channel)
│   └── IndentEngine.swift        — Indentation by file type (dependency-free)
├── Window/
│   ├── Window.swift              — Base window class (cell buffer, WindowMode modes, command line, HeaderPlate)
│   ├── EditorWindow.swift        — Vim editor
│   ├── EditorOperators.swift     — Operator-pending mechanics (EditorWindow extension): key dispatch with an armed operator (dd/yy/cc doubling, motions as arguments, death on a foreign key), applying d/y/c over NormalMotion ranges (linewise with file terminators and the cc indent, charwise, x with a count), p/P with a count
│   ├── EditorSelection.swift     — Selection subsystem: geometry of the three visual modes (charwise/linewise/blockwise — one VisualSelection currency), the v/V/Ctrl+V transition matrix, terminating operators (yank/delete/x/paste-over), block application (applyBlockEdit), highlighting; state is per-tab in EditorBuffer
│   ├── CommitWindow.swift        — Commit message editor (a layer over EditorWindow)
│   ├── TabBarWindow.swift        — Tab bar above the editor
│   ├── FileExplorerWindow.swift  — File explorer
│   ├── GitPanelWindow.swift      — Git panel
│   ├── GitBranchesWindow.swift   — Branch picker (filter + switch + create)
│   ├── SearchResultsWindow.swift — Search results (query input + tree)
│   ├── PreviewWindow.swift       — File preview (search space)
│   ├── CommandWindow.swift       — Output of long-running git commands (pull/push) + credential input
│   ├── TerminalWindow.swift      — Built-in terminal
│   └── StatusBarWindow.swift     — Status bar
└── LSP/
    └── LSPClient.swift           — Language Server Protocol client

Tests/SwimCoreTests/                    — swift-testing (`swift test`): regression fixtures for SwimCore's pure modules
├── DiffGutterTests.swift               — Unified diff formats: commit message on +/-/space, combined merge (@@@), untracked, multi-file, \\ No newline, gutter width
├── HunkLinesTests.swift                — New-line ranges of -u0 hunks: pure additions, new file, pure deletion (+c,0), header with function context, @@@ vs content @@, rename without edits, multi-file
├── PorcelainTests.swift                — Porcelain -z: regular records, rename/copy orig field, raw paths, short fields, classification precedence (MM/AM → unstaged, A /?? → added, M  → staged)
├── BranchListTests.swift               — Picker listing: 4 NUL-separated fields, git's order verbatim, remote flag, exclusion of `refs/remotes/<remote>/HEAD`, request patterns (empty — local, non-empty — heads+remotes, glob escaping)
├── AppLocaleTests.swift                — Locale: guaranteed English spelling, region-qualified id, bare language doubles the code into a region
├── InputLineTests.swift                — Input line scrolling in cells: tail at rest, Home reveals the head of overflowing text, CJK/emoji take 2 cells and are never cut at an edge, the caret is always in the window (a property-based invariant over narrow/wide texts)
├── CharWidthTests.swift                — Grapheme widths: Cyrillic 1, CJK/emoji/flags 2, zero-width 0, wide-range boundaries
├── PieceTableTests.swift               — delete across piece boundaries (the coordinate bug's shape), splits, clamping past the end, a deterministic property campaign against a byte-accurate reference; word primitives (e/w at the buffer tail, CRLF, boundaries)
├── NormalMotionTests.swift             — Operator ranges: linewise in both directions, inclusive→exclusive, sorting of backward-going ranges (db/d0/dh), the exclusive-end-in-column-0 adjustment (dw keeps the line break, db at BOL does not glue), empty ranges nil, gg/G defaults vs an explicit count
├── BackgroundTaskTests.swift           — Restartable background task: newest-wins hand-off — a run publishes exactly once, the slot is emptied by consume, a late old completion never clobbers a fresh result
├── BracketedPasteTests.swift           — Paste scanner: the payload ends at the marker, content that merely starts like it survives, CR/CRLF → `\n`
├── MarkdownTokenizerTests.swift        — Markdown structure recognition (heading/fence/rule) + the warm-cache-equals-cold-scan contract
├── MultilineInsertTests.swift          — Cursor after a bulk insert: whole lines down + graphemes on the final line (never bytes — a CJK/emoji tail is one column-step), empty lines, a dangling `\n`
├── NormalPendingTests.swift            — Pending accumulator: count slots before/after the operator (multiplication — 2d3d = 6), the g-prefix in a separate slot, explicit consumption, one reset
├── StatusListSelectionTests.swift      — Sectioned-list selection: the cursor follows the record within its section and holds the row when it moves to another section or vanishes
├── SearchTreeTests.swift               — Results tree: the full chain root → … → dir → file → lines (not the file's immediate parent alone), same-named dirs at different depths distinct, line sorting, trailing-slash root, empty → nil, out-of-root defensive path, exotic names, the root count == total invariant
├── HighlightTests.swift               — Preview highlighting session: routing by extension (swift keywords/numbers, JSON strings/numbers, markdown heading markers and fences), the ladder inside the session (a window below the `"""` opener still colors continuations), the ≥50000-line plain guard, out-of-range windows, line-numbering parity with the searcher's components semantics, unknown extensions keep the lexical pass
├── SyntaxTokenizerTests.swift          — Python string prefixes (f/r/b/u) open the string token; builtin strings absorb nested LSP interpolation tokens (pyright f-strings); the LSP merge; the string-state ladder (unclosed `"""` stays active across lines, the closing line resets; step-by-step extension equals one shot; the walk stops at the buffer's end)
├── TabPolicyTests.swift                — One tab = one indent step in spaces; tab-free text returns identical, untouched
├── SubstituteTests.swift               — :s parsing (separators, flags, the selection marks, explicit line ranges with capped overflow and dispatch regressions, nil for foreign commands), magic↔ICU translation (both directions, bracket classes, backslash), replacement segments (`&`, `\r`, `\t`, backrefs), the byte-offset plan (Cyrillic, zero-length matches, g vs first-per-line, byte windows — inside/cutting/edge rules), range resolve (clamping, backwards, the relative-second-offset rule), report word forms
├── TreeListNavigationTests.swift     — Tree-list navigation: the collapse target (nested row → nearest shallower row above, elder siblings' subtrees skipped; top level → itself; bounds/empty safe) and the first-child descend (lands on the row below one depth deeper, nil for siblings/leaves/list end)
└── VisualBlockTests.swift              — Block math in display cells: membership by cell intersection, a straddling tab splits (uncovered cells become spaces), a wide glyph is atomic, both corners inclusive
```

**Testing convention:** an SPM executable target cannot be imported from tests, so pure side-effect-free logic is factored out into the library target `SwimCore` (modeled after `IndentEngine` — dependency-free), and its contracts are pinned by fixtures in `Tests/SwimCoreTests` (swift-testing, `@Test`/`#expect`). Run with: `swift test`. Window logic (UI, delegates) is not covered by tests — it is verified by building and by hand.

---

## Detailed Module Description

### Core/Cell.swift — Screen Cell

**`Color`** (enum) — a terminal color. Supports the 16 standard ANSI colors + 24-bit RGB via `Color.rgb(r:g:b:)`. Has the computed properties `ansiFG` and `ansiBG` — ANSI escape sequences for setting the text and background color.

Grapheme width in cells (`Character.displayWidth`/`isWide`, Unicode East Asian Width table) is factored out into SwimCore (CharWidth.swift) — the single authority for the renderer, panels, and input surface scrolling; tested in Tests/SwimCoreTests.

**`Cell`** (struct, Equatable) — a single screen cell. Contains:
- `char: Character` — the displayed character
- `fg/bg: Color` — text and background colors
- `bold/dim/underline/reverse: Bool` — text attributes
- `wideContinuation: Bool` — true if the cell is the right half of a wide character (CJK/emoji)

The factory method `Cell.colored(_:fg:bg:bold:dim:underline:reverse:)` creates a cell with the given parameters.

---

### Core/Theme.swift — Color Palette

The caseless enum `Theme` is a namespace for the static Tokyo Night Storm colors:

| Property    | HEX       | Purpose                 |
|-------------|-----------|-------------------------|
| `bg`        | `#24283b` | Main background         |
| `bgDark`    | `#1f2335` | Side panel background   |
| `bgHighlight` | `#292e42` | Selection background  |
| `fg`        | `#c0caf5` | Main text               |
| `fgDark`    | `#a9b1d6` | Secondary text          |
| `comment`   | `#565f89` | Comments                |
| `blue`      | `#7aa2f7` | Functions               |
| `blue1`     | `#2ac3de` | Types                   |
| `blue5`     | `#89ddff` | Operators               |
| `green`     | `#9ece6a` | Strings                 |
| `magenta`   | `#bb9af7` | Keywords                |
| `orange`    | `#ff9e64` | Numbers/parameters      |

---

### Core/Terminal.swift — Terminal I/O

The `Terminal.shared` singleton is marked `nonisolated(unsafe)` for Swift 6.

**Setup (`setup()`):**
1. Saves the current termios settings
2. Switches the terminal to raw mode (disables echo, canonical mode, signal processing)
3. Gets the terminal size via `ioctl(TIOCGWINSZ)`
4. Switches to the alternate screen buffer (`\e[?1049h`)
5. Enables bracketed paste mode (`\e[?2004h`) — a paste from the system clipboard arrives as a single chunk wrapped in `ESC[200~…ESC[201~` instead of a stream of key presses (a key press stream broke indentation: every pasted line break went through auto-indent on top of the text's own indentation, and the indent accumulated line by line)
6. Clears the screen and homes the cursor (`\e[2J`, `\e[H`) — the cursor is not hidden here; its visibility is decided per frame by the renderer (`showCursor`)
7. Installs a SIGWINCH handler as a non-blocking self-pipe: the handler writes one byte (saving/restoring `errno` — a failed write must not clobber the `EINTR` the interrupted syscall is about to report) into a pipe whose both ends are `O_NONBLOCK` + `FD_CLOEXEC`. Both properties are load-bearing: a blocking pipe parks the drain loop in `consumeResizeEvent()` forever on the first resize (no EOF can arrive while the write end lives in-process), a blocking handler write could deadlock the process inside the signal, and CLOEXEC keeps the pipe out of children (git, LSP, the embedded shell). The handler is installed last — after the pipe exists, so an early SIGWINCH cannot write to an invalid fd

**Restore (`restore()`):** Uninstalls the SIGWINCH handler first (default disposition — a late resize must not interrupt the remaining steps via EINTR nor touch the descriptors being closed), restores the original termios settings, disables bracketed paste (`\e[?2004l`), switches back to the main buffer, shows the cursor, closes the pipe.

**Input:**
- `readByte() -> UInt8?` — reads one byte from stdin (blocking; EINTR from SIGWINCH is retried — a resize during a read, including a long bracketed-paste insertion, does not break input)
- `bytesAvailable() -> Bool` — checks for available data via `poll()` with a 5 ms timeout

**Resize:**
- `hasResizeEvent` — a pending SIGWINCH ping in the self-pipe (poll with zero timeout)
- `consumeResizeEvent()` — drains the pipe (the non-blocking drain coalesces a resize storm into the latest size) and re-reads `TIOCGWINSZ`; the run loop then applies `relayoutAndRepaint()` — the one full reaction to a terminal-size change, also serving the first frame
- `minimumWidth`/`minimumHeight` (60x5 — beside the explorer's 22-column floor the editor keeps a workable 38) and `isTooSmall` — startup refuses less (the error names the current size too); a runtime shrink paints the too-small overlay instead of a degenerate layout — two lines, the caption and `current WxH, required 60x5 at least`, so the user sees how far to stretch — and content renders are gated off until the size recovers

**Output (buffered):**
- `moveCursor(row:col:)`, `setFG()`, `setBG()`, `setBold()`, `setDim()`, `setUnderline()`, `setReverse()`, `resetAttributes()`, `writeChar()`, `writeString()` (whole-string append — one copy, no per-character Strings), `eraseScreen()` (clears with the CURRENT background — reset the attributes first when the inherited pen is untrusted) — append ANSI escape sequences to `outputBuffer`
- `flush()` — writes the entire buffer to stdout through raw `write(2)`, looping over partial writes and retrying on `EINTR` (the only handled signal is SIGWINCH, so every EINTR here is a resize arriving mid-write; the frame must not be truncated), then clears the buffer

All terminal writes go through `write(STDOUT_FILENO, ...)` directly, bypassing stdio buffering.

---

### SwimCore/PieceTable.swift — Text Buffer

Piece Table is a data structure for text editors (used in VS Code). Ideal for frequent inserts/deletes: the original buffer is immutable, all additions are appended to a separate buffer. It lives in the SwimCore target (pure dependency-free logic) and is covered by unit tests.

**delete is two-phase (plan → apply).** Phase 1 plans the cuts against the ORIGINAL piece layout in original coordinates; phase 2 applies them from the end. Mutating pieces during the traversal is not allowed: every trim shifts all subsequent bytes to the left, and `offset += deleteLen` in original coordinates no longer matches the already-shrunk pieces (buffer coordinates) — the traversal skipped pieces inside the range and cut bytes OUTSIDE it while the length bookkeeping still converged (silent content corruption; caught by a randomized stress test of editing sessions — dd across piece boundaries after active editing). The bug's shape is pinned in PieceTableTests.

**How it works:**

Two byte buffers:
- `original: [UInt8]` — the original file contents (never modified)
- `addBuffer: [UInt8]` — append-only buffer for all insertions

The `pieces: [Piece]` array is an ordered list of descriptors, each referencing a byte range in one of the buffers. The document is the concatenation of all pieces.

**Example:**
```
original: "Hello World"
addBuffer: ", beautiful"
pieces: [
    Piece(start: 0, length: 5, isAdd: false),   // "Hello"
    Piece(start: 0, length: 11, isAdd: true),    // ", beautiful"
    Piece(start: 5, length: 6, isAdd: false),    // " World"
]
→ Result: "Hello, beautiful World"
```

**Line index (`lineStarts: [Int]`):**
An array of byte offsets of each line's start. Construction:
1. On initialization — a full scan of all bytes via `withUnsafeBufferPointer` + `reserveCapacity` (an optimization for large files)
2. On insert/delete — rebuilding only from the change point (`rebuildLineIndex(fromOffset:)`)
3. Finding a line by byte offset — binary search, O(log n)

**Line cache:**
`cachedLineNum` / `cachedLineStr` — a cache of the last decoded line. `getLine()` checks the cache before creating a new String. Invalidated on insert/delete. This is critical: a single line may be requested via `getLine()`, `lineCharLength()`, `charToByteOffsetInLine()` within one frame.

**UTF-8 support:**
Internal storage is bytes. The cursor works in character positions. Conversion:
- `charToByteOffsetInLine(line:charIndex:)` — character index → byte offset
- `byteToCharOffsetInLine(line:byteOffset:)` — byte offset → character index
- `lineCharLength(line:)` — line length in characters (not bytes)

**Key operations:**
- `insert(_:at:)` — O(1) append to addBuffer + O(pieces) to insert a Piece + O(n) index rebuild from the insertion point
- `delete(at:length:)` — O(pieces) to modify/remove Pieces + O(n) index rebuild
- `getLine(_:)` — O(1) lookup in lineStarts + O(piece) to assemble bytes + UTF-8 decoding
- `search(_:from:)` — O(n) byte-by-byte search with backtracking

---

### Core/Input.swift — Input Parsing

**`Key`** (enum) — represents a key press:
- `.char(Character)` — a printable character
- `.escape` — Escape
- `.enter` / `.backspace` / `.delete` / `.tab`
- `.up` / `.down` / `.left` / `.right` — arrow keys
- `.ctrlUp` / `.ctrlDown` / `.ctrlLeft` / `.ctrlRight` — Ctrl+arrows
- `.shiftLeft` / `.shiftRight` — Shift+Left/Right (Shift+Up/Down decode as plain arrows)
- `.home` / `.end` / `.pageUp` / `.pageDown` / `.insert`
- `.ctrl(Character)` — Ctrl+letter (bytes 1-26)
- `.f(Int)` — F1-F12
- `.shiftTab` — Shift+Tab
- `.paste(String)` — bracketed paste text (the payload between `ESC[200~` and `ESC[201~`; line breaks already normalized to `\n`)
- `.unknown(String)` — an unrecognized sequence

**`Key.parse(from:)`** — reads bytes from the terminal and recognizes:
- Single bytes (printable, Ctrl combinations)
- CSI sequences (`\e[...`) — scanned in full (parameter string + final byte), then the `csiKey(params:final:)` dispatcher maps the pair to a key: arrows and tilde codes (Home/End/PageUp/PageDown/Delete/Insert/F9-F12), modified xterm arrows (`1;5X`) and rxvt (`5X`, `;5X`), CSI u (`13u` = Enter)
- Bracketed paste (`\e[200~ … \e[201~`) — the payload is read by a blocking loop up to the end marker via the incremental scanner `BracketedPaste.Scanner` (SwimCore, test-covered) and returned as a single `.paste(String)`; EOF mid-paste (a broken stream) returns the accumulated `partialText`
- SS3 sequences (`\eO...`) — arrows, Home/End, and alternative F1-F4 codes
- Shift modifiers (`\e[1;2...`) — Shift+Left/Right, Shift+Tab
- Multi-byte UTF-8 characters

Routing of `.paste` to windows: the editor inserts the text verbatim (no auto-indent) — insert mode at the cursor, normal as `p`, visual/visual-line as selection replacement (a single undo step, the replaced text goes to the yank register, like visual `p` in vim), command mode — into the command line; single-line surfaces (the command line, branch filters, the terminal prompt) accept the paste with line breaks stripped (`Window.pasteFlatLine`). In terminals without `?2004` support, pasting degrades to the old key press stream.

---

### SwimCore/BracketedPaste.swift — Bracketed Paste Scanner

A pure incremental scanner for the payload between the `ESC[200~`/`ESC[201~` markers. Bytes arrive one at a time from blocking tty reads, so the end marker is matched incrementally: content that merely starts like the marker (a lone ESC, `ESC[2`) stays content; a partial match before the real marker is not lost. CR/CRLF (which terminals actually send inside pastes) is normalized to `\n` in a single place — at the scanner's output — so the `.paste(String)` contract "line breaks are already `\n`" holds by construction. EOF before the marker yields `partialText` (payload + partial-match bytes).

### SwimCore/MultilineInsert.swift — Cursor After Multi-line Paste

`cursorDelta(for:)` — pure math: how many whole lines down and how many grapheme clusters ("characters" in cursor-column units — never bytes: a CJK/emoji tail is 2+ bytes but a single column step) on the last line. Used by all three editor paste paths (insert-paste, `p`/paste-after, selection replacement), so cursor positioning cannot diverge between them. Covered by tests (CJK/emoji tails, empty lines, a dangling `\n`).

---

### Core/IndentEngine.swift — Indentation on Line Break

A pure `plan(...)` function with no dependencies on the buffer/terminal: given the text to the left/right of the cursor, the full line, the indent width, and the `lineAbove(n)` closure (the n-th line above, nil past the start of the file), it returns a `Shape` — how to lay out lines after Enter. Vocabulary at the level of vim `smartindent`/python pep8-indent:

- **Regular break** — the current line's indent +sw if the full line ends with `{`/`(`/`:` (the suffix of the full line specifically, so `a ?: b` and mid-line breaks do not change the behavior)
- **Break before `)`/`}`** — the bracket moves to its own line with the indent of the line where the **matching opener** lives (a backward balance scan of `(`/`{` vs `)`/`}` from the cursor position; fallback −sw when unpaired). Aligning to the opener rather than "one indent less" survives manual re-indents and multi-line calls. The existing leading indent between the cursor and the bracket is not doubled — the plan returns only the top-up (`bracketPad = max(opener_indent − existing, 0)`, the result = the max of the two), so Enter inside the indent of the bracket line is idempotent
- **A fresh line for the cursor** is inserted only if the text to the left ends with `{`/`(` (the body/arguments are yet to come: `if x {|}` → cursor@+sw, `}`@base; `foo(a|)` → the bracket goes down, the cursor rides the bracket's line — parity with VSCode/IntelliJ)
- One undo action for the entire inserted text (`\n` + indents)

Vocabulary limitations (as with vim engines): brackets inside strings/comments, `[`/`]` do not participate, closure signatures (`{ x in|}`) are not recognized. The `plan(...)` contract is designed to be replaced by a provider — treesitter or LSP `onTypeFormatting` — without touching the callers.

---

### SwimCore/SyntaxTokenizer.swift — Built-in Highlighting

A linear tokenizer with per-language profiles: the full set (keywords + strings + comments) for Swift, C, C++, C#, Python, Rust, Go, JavaScript/TypeScript, Dart; a comment-only profile for shell, YAML/TOML, Ruby; JSON via a separate character-by-character pass (Markdown is factored out into `MarkdownTokenizer`).

**`SemanticToken`** — a token with the fields `line`, `startChar` (grapheme index), `length`, `type`, `modifiers`.

**`tokenize(chars:lineNum:keywords:syntax:initialState:literals:)`** — parses a single line:
- A single-line comment per the language profile (`//` or `#`; shell — only at a word boundary)
- `/* */` — a block comment (within a single line)
- Multi-line strings per the profile's rules (`"""`, `'''`, `` ` ``, `@"`, rust-`"`); an unclosed opener returns `endState .active(ruleIndex:)` — the next call resumes the line from column 0
- `"..."` / `'...'` — strings with escape support; in Python the f/r/b/u prefix (`f"x"`, `rb'…'`) is part of the string token (the quote must be immediately adjacent: `f "x"` is an identifier + a string). Escapes are honored in raw literals too — as in CPython, a raw string cannot end with a backslash
- Numbers (including hex digits)
- Identifiers → classified as keyword/literal/type/function/variable (+ soft keywords `match`/`case` in statement position)
- Operators (`+-*/=<>!&|^~%?:@#`)

**`mergeWithLSP(builtin:lsp:)`** — a layered merge of a single line: builtin tokens fill the gaps between LSP tokens (LSP wins on overlaps), except for string spans — LSP tokens nested inside a builtin string (f-string interpolations from pyright) are absorbed by it; a partial overlap still displaces the builtin token. The result is sorted by `startChar`, with no overlaps. Tested by Tests/SwimCoreTests.

For files larger than 50K lines, built-in highlighting is disabled (the `useBuiltinTokens` flag).

For JSON files a separate fast path is used — `SyntaxTokenizer.tokenizeJSON(lineChars:lineNum:)` scans character-by-character and coalesces the runs into ordinary `[SemanticToken]`s consumed by the normal token loop (what it avoids is keyword tables):
- Quoted strings → green (`Theme.green`)
- `{`, `}`, `[`, `]`, `,`, `:` → white (`Theme.fg`)
- Everything else → orange (`Theme.orange`)

---

### SwimCore/MarkdownTokenizer.swift — Markdown Highlighting

A streaming pass over the document structure (not line-by-line like the code tokenizer): fenced-block state lives across lines. `MarkdownTokenizer.Cache` — a viewport cache opaque outside the module: it remembers the last render position and the block state there; the cache is forward-only — scrolling down within 200 lines continues the scan incrementally, while scrolling up even one line (or a different buffer/line count) rescans from scratch. `isMarkdown(ext:)` — extension routing. Tested by Tests/SwimCoreTests (including warm-cache equivalence to a cold scan).

---

### SwimCore/Substitute.swift — vim-style `:s/pat/rep/[gic]`

The pure half of substitution; the effectful half lives in `EditorWindow.runSubstitute`. Pieces:

- **`parse(_:)`** — the command line after `:`: an optional range — `%` (accepted and IGNORED — the default range is the whole buffer, a deliberate deviation from vim where a bare `:s` covers the current line), one of the selection marks `'<`, `'>`, `'<,'>` (visual mode's `s` prefills `'<,'>s/`), or an explicit line range `[N|.|$][±n][,…]` (`:1,5s`, `:.,$s`, `:5,+2s`, `:+3s`; a bare second offset is relative to the RESOLVED first line — vim's rule, pinned by a fixture after base inheritance turned out to silently select the wrong lines; digit and delta accumulation is capped so a typed 99999999999999999999 cannot trap the Int), then any prefix of "substitute" as the command token, any vim-legal separator (not a letter/digit/space/`\`/`"` — `s,a,b,` works), backslash-escaped fields, flags `g`/`i`/`c` (spaces tolerated, anything else makes the command "not a :s" — it falls through to the other dispatch branches; a half-typed range is the same strictness: `:5,` and `:,s` are not :s commands, and `:5`/`:+3` keep falling to the goto-line branch). Total: no input crashes it (the only uncapped digits it reads are single `\0`–`\9`).
- **`translatePattern(_:)`** — the bidirectional vim-magic↔ICU translation, the historical inversion handled in both directions: `\(`, `\)`, `\|`, `\+`, `\?`, `\{` (special in vim) become bare; bare `(`, `)`, `+`, `?`, `|`, `{` (literals in vim) get escaped; a bare `}` stays bare (it closes a `\{n,m}` quantifier as-is); `\<`/`\>` become `\b`. Bracket classes pass through untouched (POSIX `[[:alpha:]]` included; a `]` right after `[` or `[^` is a member). The magic-mode prefixes `\v` `\m` `\M` `\V` are REJECTED with an error — ICU would silently read them as its own escapes (`\v` is a vertical tab there) and the pattern would match something the user never wrote.
- **`translateReplacement(_:)`/`expand(...)`** — the replacement as segments expanded by Swim itself (no ICU template): `\0`–`\9` and `&` = the whole match, `\r` = a LINE BREAK (vim's rule — \r is what breaks the line; the `\n`→NUL quirk is not reproduced), `\t` = a tab, `\&`/`\\`/`\<sep>` are their literals, an unknown `\x` is the literal x. `maxGroup(in:)` validates back references against the compiled pattern BEFORE any edit is applied (vim's E65).
- **`edits(...)`** — the plan over whole lines (text without its terminator — the FULL terminator grapheme: on a CRLF file `"\r\n"` is one Swift Character, and a `hasSuffix("\n")` strip would leak it into the matchable text where ICU's `\s` would swallow it and join lines; so `$` anchors to the line's content end and a pattern cannot match across lines), in ORIGINAL-buffer BYTE offsets — ICU matches arrive in UTF-16, and the one conversion lives here. A line's optional `byteWindow` restricts matches to a column band — the blockwise selection's territory: a match is kept only when it lies ENTIRELY inside the window (zero-length matches are admitted on either boundary). Zero-length matches are kept (`:s/^//` reports "1 substitution"). Edits come back ascending: the editor's plain path applies them in REVERSE (an edit never shifts the offsets of the edits before it — no delta bookkeeping), the `c`-flag session walks them forward with a running byte delta.

The editor side: the scope of a `'<,'>s` command is the selection that armed the command line — `s` in ANY visual mode (EditorSelection.prefillSubstituteFromSelection) resolves the selection's geometry once (charwise/linewise — whole lines, the `'<,'>` semantic; blockwise — the lines PLUS the block's display span) and opens the command line prefilled `'<,'>s/`; the captured scope is stale-proof by construction (armed AFTER enterCommandMode — entering a command line clears any previous scope; consumed by the next `:s` execution; unreachable by edits — the command line owns every key between arming and Enter, and a manually typed `'<,'>` after the session died reports "Selection range expired" instead of substituting by shifted line numbers). For a block, per-line byte windows come from the tested `VisualBlock.charRange` (via `blockSlice`) converted with `charToByteOffsetInLine`. One composite `recordAction` over the whole substituted range — the entire command (including a confirm session interrupted by `q`) is a single undo step and a single LSP `didChange`; an equality guard skips the record when no byte changed (`:s/^//` sets no modified flag); the report ("N substitutions on M lines") shows in the status bar and clears on the next key, like vim's. The `c`-flag confirm rides the write-confirm's modality: the session owns the command line (command-mode routing is the first consumer of every key in Application), the cursor parks on each upcoming match, and `y/n/a/q/l/Esc` decide — an all-`n`/first-`q` session leaves no record and no message. Deviations kept deliberately: line ranges clamp instead of erroring past the buffer (`:0s` = the first line; vim's virtual line-0 is not reproduced), a backwards range reports "Backwards range" instead of vim's interactive swap, incomplete ranges are rejected rather than guessing vim's missing-address defaults, no `~` (previous replacement), no `\u\l\U\L\E` case modifiers, no `I` flag or `\c`/`\C` inline controls, and the shared search pattern is searched literally by `/`-`n`/`N` (the editor's `/` search is literal — a pre-existing trait, not a :s one). Planning materializes the buffer's lines once — O(buffer) memory and a per-line `getText` walk for one command (the same complexity class the multiline-string state rebuild already pays).

---

### Window/Window.swift — Base Window Class

An abstract base class for all UI panels. It implements a virtual cell buffer, the unified mode model, the command line, and the header plate mechanism.

**Cell buffer:** A flat `[Cell]` array of size `width * height`. Cell index = `row * width + col`.

**Modes (`WindowMode`)** — belong to the window; each one declares the available set via `availableModes`:
- `.menu` — standard behavior of list windows (git panel, explorer, search): j/k by rows, Enter — the primary action ("drill in"), other action keys — specific to the given window
- `.normal` / `.insert` / `.visual` / `.visualLine` / `.visualBlock` — editor modes; list windows reuse `.visualLine` for line-wise selection
- `.command` — a command line belonging to the window that opened it

`mode` — a computed property over private storage; `EditorWindow` overrides it, storing the mode per-tab (in `EditorBuffer`).

**Command line (base class methods):**
- `enterCommandMode(prefill:)` / `exitCommandMode()` — enter/exit (the prefill places ready-made text and puts the cursor at the end); exiting returns to `.menu` (for menu-type windows) or `.normal`
- `handleCommandModeKey(_:)` — the shared key handler: the buffer is typed through the status bar with a visible cursor (`commandCursorPos` — arrows/Home/End move it, Delete deletes forward, backspace on an empty buffer exits the mode), Enter — the only intercepted key — executes the command against the owning window, Esc cancels. The mode is exited **before** execution — `:q` does not leave a stuck `.command` on the closed window. Command mode is an insert surface in the status bar: the window provides the caret position via `cursorRenderInfo()` (terminal cursor bar, the same shape as insert), and the status bar itself pulls the buffer and caret from `commandSource` (a weak reference to the source window) — Application merely aggregates: `visibleWindows.compactMap { $0.cursorRenderInfo() }.last`; a long command scrolls by the shared `InputLine` policy (SwimCore, tested) within the space between the mode label and the right block — the right block is fixed and always displayed (and never rides onto the mode label — on narrow widths it is the block that gets clipped), the text window follows the caret (tail at rest — the last typed characters stay visible), and one cell of the area is reserved for the caret; measurement is in terminal cells (`CharWidth`, SwimCore): a wide CJK/emoji takes two cells, cannot push the caret under the block, and is never cut at an edge; over the center's informational texts (errors, diagnostics, branch) the previous priority holds — the block wins the overlap, those are display-only, clipping is acceptable
- `executeCommand(_:)` — the base implementation handles the commands shared by all windows (`q`, `q!`, `quit`, `bd`, `qa`, `terminal`, ...); the editor overrides it with file ones (`w`, `wq`, `e`, `:s` (see Substitute), `/<query>`)
- `applyLineEdit(_:text:cursor:)` — a shared key→edit mapping for the windows' own single-line input surfaces (the picker's filter and branch name, the search query, the terminal prompt): backspace/delete/arrows/Home/End/single-character input → `LineEditOutcome` (`.notEditing/.caretOnly/.textChanged`). A stateless pure function; "what an edit means" (re-querying git, scrolling to the prompt) stays with the caller. The command line (`handleCommandModeKey`) deliberately keeps its own branch — a different contract: any character can be inserted (no guard filter), backspace on an empty buffer exits the mode, Enter/Esc are intercepted before editing

**Header plate (`HeaderPlate`):** an optional plate row at row 0 — `headerPlate` (text + colors), `contentTop`/`contentHeight` (content geometry below the plate), `drawPlate()` from `update()`. Used by the terminal (`Terminal @ dir`), the git panel (`Git @ branch` and diff-view headers), and the commit window (`Commit @ branch`).

**Key methods:**
- `setCell(_:_:_:)` — sets a cell with bounds checking. Sets `dirty = true` on change
- `getCell(_:_:)` — returns a cell (`.blank` out of bounds)
- `fillRegion(row:col:width:height:cell:)` — fills a rectangular region
- `writeString(_:row:col:fg:bg:bold:)` — writes a string into the buffer with handling of tabs (4 spaces) and wide graphemes (CJK/emoji — 2 cells, the right one marked `wideContinuation` for the renderer; a glyph that does not fully fit is dropped — never split)
- `handleKey(_:) -> Bool` — override point for key handling
- `update()` — override point for cell buffer updates

**Dirty flag:** `dirty = true` means the cell buffer has changed — a write-only vestige (never read, kept for potential future use): `Application.render()` always forwards all visible windows, and `Renderer` does its own cell-level diff against the previous frame (`prevScreenCells`).

---

### Window/EditorWindow.swift — Main Editor

The central component is a vim-like modal editor.

**Tabs (`BufferManager`):** each file is open in its own tab — `EditorBuffer` holds per-file state (PieceTable, cursor, scroll, undo/redo stacks, LSP pending changes, semantic tokens, diagnostics, markdown cache, mode). EditorWindow forwards its properties to `tabs.active` via computed accessors — the external interface is unchanged. Paths are normalized to absolute (`BufferManager.normalize`) — tab dedup and LSP uri matching are stable.

- Opening a file — a new tab or a switch to an existing one (dedup by path)
- `gt` / `gT` — next/previous tab (wrap-around), `:bd` / `:bd!` — close, `:e file` — replace the current one (vim)
- Closing the last tab removes the editor from the window stack: focus goes to the window below it (usually the explorer); if the stack is empty — the application exits
- `Ctrl+X` — close the focused window (in the editor — the current tab, refusing when there are unsaved edits; in panels — the panel itself), `Ctrl+Z` — close all other tabs except unsaved ones (they remain with a message)
- Closing a tab sends LSP `textDocument/didClose`; late-arriving tokens are routed to the owning tab by uri
- The tab bar (`TabBarWindow`, height 1) is visible together with the editor; the active tab is highlighted, `+` = modified; on overflow it scrolls so the active tab is always visible

**Modes (`WindowMode`, stored per-tab):**
- `.normal` — vim grammar `[count1] operator [count2] motion` (3dd, d3d, 2d3d=6 lines, dw/de/db/d$/d0/dh/dl/dj/dk/dG/dgg + y*/c*, aliases D/C/S (d$/c$/cc, cc keeping the indent) and Y = y$ — a deliberate difference from vim (there Y = yy, a historical wart from :h Y): the D/C/Y family consistently acts from the cursor to the end of the line, with a count as for a motion (3Y = 3y$)) and motions with a count (3j, 5w, 2G, 5$). Dispatch is three-stage: gPrefix (two-letter gg/gt/gT/gb/gd; under an operator only gg is valid as a motion) → operator-pending (an armed d/y/c intercepts ANY key — a motion cannot "slip past" the operator, a foreign key kills the sequence, like a vim error) → regular commands. State is `SwimCore.NormalPending` (count before/after the operator with multiplication, operator, g-prefix in a separate slot), motion/range math is `SwimCore.NormalMotion` (exclusive/inclusive/linewise, exclusive-end adjustment; both tested). The single-reset-point discipline: arming either explicitly kept the sequence (keepPending), or the deferred tail of handleNormal killed it (closed classes of leaks: `dv…Esc d`→`dd`, `gxg`→`gg` with a stale g, simultaneous arming of d and y); interceptions that bypass handleKey reset explicitly — bracketed paste (handleKey), global hotkeys/Tab/foreign windows (`interruptPending` from Application) and the command line (`enterCommandMode`) — the `d : Esc d`→`dd` class.
- `.insert` — text input (Escape to exit); Enter lays out lines via `IndentEngine` (see Core/IndentEngine.swift) — a regular break (+sw after `{`/`(`/`:`), a break before `)`/`}` moves the bracket to its own line aligned to the matching opener, a fresh cursor line — only when there is `{`/`(` to the left of the cursor
- `.visual` — visual selection (y — copy, d/x — delete, s — the substitute prefill `'<,'>s/` for the selection's lines, a — select all)
- `.visualLine` — line-wise selection (Shift+V; y — copy, d/x — delete, s — the substitute prefill, a — select all, Shift+Right/L or Shift+Left/H — shift lines by the language's standard indent: indent/outdent as a single undo action, the selection is preserved)
- `.visualBlock` — rectangular selection (Ctrl+V; y — blockwise yank, d/x — block deletion filling the register blockwise, pasting from the system clipboard — block replacement, s — the substitute prefill restricted to the rectangle's column band, a — select all rows with the rectangle widened to the widest line; see "Visual block" below)
- The entire mechanics of the three visual modes is a single subsystem `Window/EditorSelection.swift` (an EditorWindow extension, state per-tab in EditorBuffer): geometry — a single `VisualSelection` value (charwise/linewise/blockwise) resolved from "anchor + cursor" once per operation; the yank/delete/paste-over operators — dispatched by geometry (single points `yankSelection`/`deleteSelection`/`replaceSelectionWithPaste`); v/V/Ctrl+V transitions — one `switchVisualMode` matrix with anchor rules (from normal the anchor = cursor; visual↔block the anchor is preserved; from visualLine the col-anchor = cursor); the invariant "a terminating operator exits to normal by itself" (the H/L-shift exception — repeatability). A deliberate difference from vim: in vim a repeated key of the SAME kind ends the mode (:h v_v, transition table), swim ignores it — the selection lives until Esc/an operator. Deliberately NOT merged: motion (grapheme clamping / lines only / virtual cells) and line-wise highlighting with the gutter.
- `.command` — the command line (:w, :q, :wq, :q!, :qa, :qa!, :e path, :e! path, :bd, :bd!, :s/pat/rep/[gic], /search). Opened from any window via `:` on the focused window — the command is executed against the owning window (see Application). Key input and the buffer are the base `Window`'s shared methods

**Bracketed paste (`.paste`):** a paste from the system clipboard is intercepted in `handleKey` before mode dispatch (also resetting pending — `pending.reset()` + the insert quote: paste terminates any sequence) and goes in verbatim, bypassing `IndentEngine` (auto-indent on top of the text's own indentation would accumulate line by line). The only normalization is the tab policy: every `\t` of an external paste is expanded to one indent step (`indentSize()`, the pure `TabPolicy.expandTabs` in SwimCore — tested) — the same width that auto-indent and H/L produce, so a pasted indent reads as a typed one; the internal `p`/`P` round-trip does NOT apply the policy — register contents must come back byte-for-byte. **The linewise register type is sniffed by scalars** (`MultilineInsert.endsWithLineBreak`, SwimCore — tested): in Swift CRLF is a single grapheme, `hasSuffix("\n")` is false for a CRLF register — a latent bug, masked while yy/dd normalized terminators to LF; now linewise registers (`yy`, `dd`, `Vy`…) carry the file's terminators (CRLF file → CRLF register → the `p` round-trip does not recolor lines), and the last line without a break gets a forced `"\n"` so the register stays linewise. Routing mirrors the vim equivalent: insert — under the cursor (`insertPasteAtCursor`), normal — like `p` (`pasteTextAfterCursor`, shared with `p`/`P`), any visual mode — selection replacement (`replaceSelectionWithPaste`: the replaced text goes to the yank register and OSC 52, like visual `p`; delete+insert as a single undo step; the cursor — on the first inserted line for a linewise paste, parity with `p`; block — see "Visual block"), command — into the command line (the single-line variant via `Window.pasteFlatLine`: `\n` is dropped as in the vim cmdline, `\t` → one space — "git<TAB>status" stays two words). The cursor position after a multi-line paste is the single pure `MultilineInsert.cursorDelta` (SwimCore, scalar counting of line breaks) for all paths. The Tab key in insert mode follows the same language policy: `indentSize()` spaces. **Ctrl+V in insert (i_CTRL-V)**: with the quote — the next key is inserted literally in raw form (Tab → a real `\t`, Enter → `\r` without auto-indent, Esc → 0x1b, Ctrl+\<c> → a control byte, Ctrl+V Ctrl+V → 0x16); a motion removes the quote and is handled the usual way; control characters in the line are invisible (zero-width, like combining marks — the column math stays consistent via Character.displayStep).

**Visual block (Ctrl+V, `.visualBlock`):** a rectangular selection that lives in display columns (terminal cells), not grapheme indices — lines with tabs and wide characters produce an honest rectangle. The block's cursor corner is a VIRTUAL column (`visualBlockCol`, per-tab, display cells, not clamped to the line length): the block does not shrink on short, empty, and phantom (past a trailing `\n`) lines, the width survives crossing them — curswant, but in cells, because the block's geometry is display-based; curswant itself (`desiredCol`) is stored in display cells for regular motion too (vertical moves resolve it via `charIndex(atDisplayCol:)` — the target line's tab layout does not shift the desired screen column), and entering the block from visual takes it as the corner: the round-trip `Ctrl+V → v → Ctrl+V` returns the corner exactly, including mid-tab/mid-wide-glyph (verified: `^V h v ^V d` == `^V h d`). State invariant: `cursorCol` always remains a REAL grapheme boundary at/after the virtual column (synchronized after every motion) — the renderer, the status bar, and all existing consumers see a meaningful position, while virtuality is read by only three branches: the caret/scroll (`drawCursor`/`ensureCursorVisible` follow the rectangle's edge even past EOL) and the status-bar column (it shows the virtual one, like vim). Motion in block mode has its own handler, not the shared `moveCursor*` (those clamp): `h`/`l` move the virtual column by one cell with no upper bound, `j`/`k` the line; paging (`Ctrl+J`/`K`, `Ctrl+Down`/`Up`, `PageUp`/`PageDown` — all five in normal and every visual mode; insert handles only PageUp/PageDown) uses the shared `pageDelta` (a page − 2 context lines, at least one) through the same `moveBlockVertically`; scrolling is pulled up at the end of the handler along both axes. The anchor is the real entry point (shared with visual `visualStartLine/Col`; V/Ctrl+V switch the selection kind preserving the anchor — `v` itself is a dead key in charwise visual, a deliberate divergence from vim: the selection lives until Esc/an operator); both corners are inclusive, as in vim: Ctrl+V + l = two cells, Ctrl+V + h too (the span is built by `Span.inclusive` — [min, max + 1); "+1 to the cursor corner before ordering" cut off the cursor's cell when moving left — a regression, covered by tests). Highlighting colors exactly what the edits touch: the cell INTERSECTION rule — a grapheme is affected ⟺ its cells intersect `[left, right)` (unified across highlighting/yank/edits, verified against vim). A tab cut by the edge is colored by its covered cells (it splits — tab cells are independent, the renderer draws them as spaces), a wide glyph — entirely (atomic; edits take it whole too); "colored but not operated on" does not exist. In edits the affected glyph splits: uncovered cells come back as spaces in the prefix/suffix (`rowPlan`), the tail is aligned to the block's left edge on every line — block `d`/paste-over keep tab alignment, as in vim. Partially covered glyphs go into the yank as spaces of the covered cells (vim yanks the visible strip). Empty cells past the end of the line inside the strip are colored onward — the rectangle reads on short lines. The register type is vim's: a block yank marks the yank register blockwise (`yankIsBlockwise`), `p`/`P` insert it as a rectangle at the cursor's display column across consecutive lines, short lines padded with spaces up to the column; for a blockwise register p and P coincide ("before/after" is meaningless for columns). Operations use INTERSECTION semantics: yank yields empty lines to those that fall short, delete does not touch them (no destructive padding), paste-over (bracketed paste in a block, vim visual `p`: the replaced text goes into the blockwise register) pads up to the column, replacing the first min(block lines, pasted lines) lines — the rest of the block is untouched (more conservative than vim, which clears the whole block; a height mismatch does not destroy neighboring content). Operations are applied as ONE contiguous replace by a line-wise span (`applyBlockEdit`, the shiftVisualLines technique: lineStart of the first changed line .. lineEnd of the last; the insertion = reassembled lines, each with its original "\n"/"\r\n" terminator; unchanged lines between the bounds are reassembled identically) — the undo model does not change, each block operator = one undo step, as in vim; after the edit the virtual column is synchronized with the real cursor. All the math is the pure `SwimCore/VisualBlock.swift` (tested): display column ↔ grapheme index resolution, cell ranges of graphemes (`glyphCells` — the single source of membership/splitting/highlighting), line slices by cell intersection, splitting of tabs and wide remainders in `rowPlan`, split-aware yank (`blockText`), reassembly with padding, Span with the width ≥ 1 invariant and a point span for pure insertion, full geometry from state (`blockGeometry`: a real anchor grapheme + a virtual corner → lines and an inclusive span — the window-side `blockRowsAndSpan` stays pure wiring with no math). Deliberate v1 limitations (degraded versions would be a surprise; it is more honest for them to be absent; the architecture does not block them): no `A`/`I`/`c` (needs an insert-replay machine — inserting text on every line at Esc, a separate feature; padding up to the column already exists in rowPlan), no `$` stretching to line ends (a "per-line right edge" flag on top of the same span), no `o` corner swap, blockwise `p` does not create lines past the buffer end; the splitting cases are verified by scripts against live vim 8.2/nvim 0.11, with deliberate deviations in micro-cases (vim itself is inconsistent, swim is uniform): a block entirely inside one tab vim ignores — swim splits it; a block yank inside one wide glyph vim yields the whole glyph — swim yields spaces of the covered cells; the uncovered right part of a wide glyph vim does not compensate for (the tail shifts) — swim pads with a space, as with tabs. Column arithmetic has one authority: `Character.displayStep(atDisplayCol:tabWidth:)` (CharWidth, SwimCore) is consumed both by the editor's rendering (`displayColForChar`/`charIndexAtDisplayCol` — thin delegates of VisualBlock) and by VisualBlock itself. Disk-reload carries `visualBlockCol` over together with `desiredCol`.

**Confirming `:w` when the file changed (vim W12):** if the file was rewritten externally since the read (buffer mtime ≠ disk mtime — edits accumulated while git-pull/the terminal/an external tool was changing the file), `:w` refuses to overwrite silently: the editor programmatically enters command mode (the established modality mechanism — all keys, including `:` and global toggles, go to the owner) and draws a red question in the middle of the status bar: `Changed on disk — w: write, r: reload (discard edits), q: quit, a: abort`. One key decides: `w/W` — write anyway (`performWrite`, bypassing the check); `r/R` — reload discarding edits (`reloadActiveBufferDiscardingEdits` → forced reload + full LSP sync); `q/Q` — close the tab; `a/A/Esc` — abort ("Write aborted"); other keys re-ask (modally, like vim). `:wq`/`:x` do not close the tab if the write did not happen (`saveOrConfirm` returns false); also, `:wq` on a `[No Name]` with text no longer loses the buffer silently — "No file name".

**Header plate:** when `headerPlate` is set, the content (line numbers, text, cursor, visual highlighting, scroll, PageUp/Down) is computed from `contentTop`/`contentHeight`; without the plate the geometry is bit-for-bit as before. Used by `CommitWindow`.

**CommitWindow** — a thin layer over EditorWindow for the commit message: the only specialization is that `executeCommand` redirects `w`/`wq`/`x`/`wquit` to `delegate.requestCommit()` (the message = the commit); everything else (including `q`/`q!`) goes to the base. Opens in insert mode in the command window slot below the git panel (the `c` key — or `C`/`A` for a prefilled/amending session), with the `Commit @ branch` plate (`Amend @ <hash> branch` for `A`: `:w` then runs `git commit --amend` — the intent lives in Application's `commitIsAmend`/`commitAmendTarget`, set on every open/refocus request and consumed by `requestCommit()`). The entire editor toolkit works out of the box: undo, visual, `/` search, `:s`. Canceling — `:q`, `:q!` or a double Esc (insert → normal, the second Esc closes the window); `:` in insert is a literal character (subjects like `feat: ...` can be typed freely).

**Go to definition (`gd`) / go back (`gb`):** the cursor position is converted to UTF-16 (`utf16ColForCharIndex`) and `textDocument/definition` is sent to the active LSP client. The response (Location/LocationLink[]) arrives asynchronously into `pendingDefinition` (NSLock); `pollLSP()` performs the jump: uri → path → tab (new or existing — dedup, no reload of unsaved buffers) → `goToPosition` (UTF-16 → graphemes, with clamping). Before the jump the origin position is pushed onto the return stack (limit 50); `gb` pops it and jumps back by the same mechanism. Not found / no server / empty stack — a message in the status bar.

**Coordinate system:**
- `cursorLine` / `cursorCol` — cursor position in characters (not bytes!)
- `scrollY` — the top visible line (a line index); `scrollX` — horizontal scrolling in display cells (resolved to a grapheme per line via `charIndexAtDisplayCol`)
- **Desired column (vim curswant):** `desiredCol` is stored per-tab in `EditorBuffer` next to `cursorCol` — in display cells (the screen column), not graphemes. Vertical movements (`j`/`k`/arrows/PgUp/PgDn — all modes, the shared `moveVertically`) do not recompute the column from the previous clamp — they resolve it through `charIndex(atDisplayCol:)`, so the target line's tab layout does not shift the desired screen column. All other positionings (horizontal, input, `gd`/search jumps, undo, `:s`, backspace joining) update `desiredCol = displayColForChar(...)` at the end of the mode handler (`isVerticalKey` is the exception). Result: the column survives short lines and the insert→normal transition without vim's leftward shift
- The position "past the last character" (col == len) is legal in all modes (analogous to `virtualedit=onemore`): insert needs it for appending; all consumers are guarded (`x` — no-op, `p`/`P` and visual ranges are computed via `charToByteOffsetInLine`, which clamps to the line length; rendering — min-clamp). Before that, the only producer of col == len was already `byteToCharOffsetInLine` (undo/jumps), i.e. the state is not new
- Conversion to bytes — via `PieceTable.charToByteOffsetInLine()` on insert/delete

**Rendering (`update()`):**
1. Fill the background with `Theme.bg`
2. Line numbers in the left column (width: `max(4, digitCount + 2)`); the gutter's last cell is the diagnostics slot (see below)
3. For each visible line:
   - JSON → `SyntaxTokenizer.tokenizeJSON` — a character-by-character pass producing ordinary tokens (no keyword table)
   - LSP tokens available → `SyntaxTokenizer.mergeWithLSP(builtin:lsp:)` layered over `semanticTokensFor(line:)`
   - Otherwise → `SyntaxTokenizer.tokenize()` (only for files <50K lines)
4. Visual selection highlighting
5. Cursor drawing (reverse video in normal; in insert `drawCursor` steps aside and the renderer draws the terminal caret — a DECSCUSR bar, shape 5)

**Git gutter (line number coloring):** the per-line status of the active file is computed by an Application background task (see status bar) — `GitLineStatus` is stored on `EditorBuffer` (survives tab switches; `applyGitLineStatus` applies it to the tab owning the path, even if the fetch catches a tab switch). Sources: `git diff --unified=0` (worktree vs index) and `git diff --cached --unified=0` (index vs HEAD); the new-line ranges are collected by the pure `HunkLines` (SwimCore, tested). Number coloring priority: unstaged (`Theme.unstagedColor`, orange) → untracked file, all lines green → staged (`Theme.stagedColor`, blue1); a line present in both trees shows unstaged — the state the next `:w` will write. The gutter reflects the last saved disk state (the live buffer is not diffed). Updates: saving, opening/switching a file, stage/unstage/discard in the git panel, git commands and terminal commands (`fetchGitStats` via `gitWorktreeChanged`/`gitCommandFinished`/`terminalCommandFinished`).

**Diagnostics markers in the gutter:** the line number is no longer colored by severity — instead, a small dot `•` (half the cell height) is placed in the gutter's trailing cell (`drawLineNumberRow` with the `mark` slot): red — error, orange — warning, yellow — info/hint. Error + warning on one line — a small square `▪` (half the cell) in the color of the worse severity (red): the "square" shape signals "more than one problem", and a two-color pair in one cell smaller than half a cell is impossible — an fg/bg split fills the entire cell; the full-height fill `▀` was rejected in favor of compactness. The mark covers the trailing space, the gutter width does not change; the mark's background is always `Theme.bg`, so the line's visual-line highlighting does not conflict with the mark.

**Token type to color mapping:**
keyword → magenta, string → green, number → orange, comment → gray, type → blue1, function → blue, variable → fg, operator → blue5

---

### Window/FileExplorerWindow.swift — File Explorer

A panel with a directory tree. Rows go through the shared cell pipeline (`Window.textCells` to assemble styled cells, `Window.drawCells` to paint the horizontal-scroll window — the same pipeline the search results use; wide glyphs in file names claim their continuation cells, and the scroll bound counts cells via `Window.cellCount` — a CJK/emoji name used to shift the row's tail by a cell per glyph). When a file is opened from a search result (Enter in the search space), the explorer expands the branch down to that file and selects it (`reveal(path:)` — expands ancestors, selects the node; paths outside the root are ignored, and paths inside hidden directories are unreachable while the listing filter is on — `H` disables it). Two of its navigation rules run on the shared pure policy `TreeListNavigation` (SwimCore, tested) — the same one the search results use: the `h` collapse target (the policy's invariant — the nearest shallower row above IS the parent directory by the flatten order — replaces the walker's old inline `isDirectory` check, behavior-identically) and the Enter/`l` descend onto the first child.

**Sync with the active file:** while the explorer is open, the tree points at the editor's current file — a single funnel `revealActiveFileInExplorer()` (Application) is called from every "current file" event: `activeFileChanged` (switching `gt`/`gT`/Ctrl+H/L, opening, closing a tab, `:e` — the event fires only when the path changes), `openFileAtLine` (an explicit call covering the case where a search result lands in the already active tab — there is no event), starting `swim file.swift` (the init event is useless: the explorer is not yet visible and has no root — reveal happens after `loadDirectory`), and reopening the explorer (`Ctrl+E`). A closed explorer is not touched — the tree is frozen, without flattening or lazy loads; on opening, it syncs with the active file instead of the stale selection. A `[No Name]` tab has no path — no-op. Reveal nuances: collapsed ancestors are re-expanded (the "show where we are" semantics, like reveal in VS Code); the first reveal of a deep path lazily loads every unloaded ancestor from disk (one batched `git check-ignore` per level), after that the `isLoaded` cache makes repeated switches cheap.

Side panel with a file tree. Supports expanding/collapsing directories, selecting files, emoji icons for file types.

**Data structure:**
- `FileEntry` — file/directory (name, path, isDirectory, isExpanded, children, isLoaded)
- `rootEntries: [FileEntry]` — root entries
- `flatEntries: [(entry: FileEntry, depth: Int)]` — flat list of visible entries

**Controls:**
- `j/k` — up/down
- `Enter` — for a file, open it; for a directory, toggle: a collapsed one expands and moves to the first child, an expanded one collapses (the cursor stays)
- `l/Ctrl+Right (Ctrl+L)` — expand a directory and move to its first child; for a file, open it (never collapses)
- `h/Ctrl+Left (Ctrl+H)` — move the cursor to the parent node and collapse it (at the root node, collapse the node itself)
- `left/right` — horizontal shift of file names (step of 4, for viewing long names)
- `g/G` — jump to top/bottom
- `H` — listing filter: hidden (dot) and git-ignored entries are not shown by default; `H` (Shift+h) rebuilds the flat list in memory — instantly, without a rescan or subprocesses (entries with flags remain in the model); the selection stays on the same entry if it survived the refilter, otherwise it is clamped
- `a` — new file/directory: opens the command line prefilled with `create ./<relative_path>/` — the `./` prefix emphasizes that the path is relative to the tree root (inside the selected directory, next to the selected file; `create ./` for an empty tree). The command `:create ./a/b/file.swift` strips the leading `./` and creates intermediate directories; a trailing `/` creates a directory. Validation: only relative paths without `..`; a duplicate or a filesystem error is reported in red in the status bar (`reportError`). On success the tree is rescanned preserving expansion (`reloadPreservingExpansion` — `loadDirectory` would collapse everything) and the new entry (file or directory) is expanded/selected via `reveal(path:)`. The command is also available manually via `:` — it is executed by the owner window (the explorer overrides `executeCommand`)
- `d` — delete: command line with `delete ./<selected path>` (trailing `/` — a directory, deletion is recursive). The visible command buffer is itself the confirmation: Enter deletes, Esc cancels. `.` components are forbidden (a lone `.` would resolve to the tree root); not found / filesystem error — reported in red in the status bar; after deletion the tree is rescanned preserving expansion, the selection is clamped. Deleting a file open in a tab does not touch the in-memory buffer (`:w` will recreate the file — vim semantics)
- `r` — rename/move by editing the path in place: prefilled `rename ./<selected entry's path>` with the cursor ready for retyping the name — before a directory's trailing `/` or before the file's `.extension` (without an extension, at the end of the name): erase the name — you rename; edit the directories — you move (`moveItem`, files and directories). The old path is captured when `r` is pressed (`pendingRenamePath`); Enter applies the command to it; the right side is a bare name (next to the old file) or a `./` path from the root. Spaces in names work; `:rename` without a capture — a clear error. Duplicate / same path / not found / filesystem error — in red; on success the tree is rescanned (fresh ignore verdicts — the new name may turn out to be dotted or match a gitignore pattern, in which case the entry disappears from the listing and the selection is clamped to a real row) and the new path is selected via `reveal(path:)`

The listing filter (on by default): filtering happens when the flat list is built (`flattenEntries`), not at load time — `loadEntries` puts **all** entries into the tree, marking `isHidden` (dot files, for free) and `isIgnored`. Ignore verdicts come from one batched `git check-ignore --stdin -z` per loaded directory (NUL separation in both directions — "raw" paths with exotic characters survive; the workDir is the directory itself, so bare names resolve in the right pattern context). Git itself computes all `.gitignore` levels (root, nested, excludes, `!` negations, root-anchored rules) and never reports tracked files — exactly the semantics the tree needs. Children of ignored directories get the flag without a subprocess: git does not re-include inside an excluded subtree. Exit codes: 0 — some names are ignored (stdout lists them), 1 — none, anything else (no git / not a repository) — the filter is not applied; outside a repository the tree shows all non-hidden files. Flags are cached at directory load time and live until its rescan — an external `sed -i .gitignore` or files created outside swim are synced by the `:fe reset` command (a full rescan preserving expansion and selection). `create .gitignore` with the filter on will create the file on disk, but it will not appear in the tree — `H` will show it. Directories sort before files.

Emoji icons: 🐦 Swift, ⚡ JS/TS, 🐍 Python, ⚙ Rust, 🔵 Go, 🌐 HTML, 📝 Markdown, 📋 JSON, etc.

**Git file name highlighting:** file names (not directories — files only, icons stay neutral) are colored by git status: a new/untracked file (`??`) — green; all changes staged (`M `/`R `/…) — `Theme.stagedColor` (blue1); at least one unstaged change (` M`, `MM`, `AM`) — `Theme.unstagedColor` (orange); priority over staged — this is the state of the next `:w`; the classification is `GitChangeClass.classify` — SwimCore, tested). The git decoration palette is centralized in the constants `Theme.stagedColor`/`Theme.unstagedColor`/`Theme.deleteColor` — the gutter, the explorer, and the panel letters read the same constants. Application places the marks from the same background `git status --porcelain -z --untracked-files=all` through the shared parser `Porcelain` (`-uall` expands untracked directories into individual files — the tree shows files, not a collapsed `?? dir/` entry). Keys are in the tree's coordinate system (dir + the rest of the path below the repo root, both sides resolved through symlinks): the repo root and the starting directory may differ both by subdirectory and by symlink view, while the tree lives in the view of the starting directory; entries outside the subtree are not keyed. Coloring is a pure lookup at draw time, so lazy child loads and rescans pick up the marks for free (`setGitMarks` compares and dirties the window). The mark wins over the selection color — the selection is already visible via the row background. Updates — the same events as the git gutter (save/open/stage/discard/git commands; `create`/`delete`/`rename` in the explorer call `gitWorktreeChanged`).

---

### Window/GitPanelWindow.swift — Git Panel

Git integration panel: staged/unstaged/untracked files, recent commits, diffs of files and commits, stage/unstage of files and individual hunks, discard, commit, pull/push. Modes: `.menu` (standard behavior), `.visualLine` (line-wise selection), `.command` (`:q` closes the panel).

**Data (`BackgroundTask` background tasks, polled in `poll()`):**
- `gitTask` — `rev-parse --abbrev-ref HEAD` (branch) + `rev-parse --show-toplevel` (repo root) + `status --porcelain -z` + `log -10 --format=%h|%an|%cr|%s`
- `diffTask` — `git diff [--cached] -- <path>`; for untracked — `git diff --no-index /dev/null <path>` (run from the repo root — porcelain paths are always relative to the root); for a commit from the log — `git show <hash>`
- `-z` produces NUL-separated records with raw paths: Cyrillic and other non-ASCII paths are not escaped; rename/copy records carry the old path as a separate NUL field — parsing goes through the shared pure parser `Porcelain` (SwimCore, tested; the panel keeps `origPath` in `GitFileStatus` for discard/unstage of renames), the same parser feeds Application's git decorations — the subtle orig-field logic lives exactly once

**Paths and pathspec magic:** all pathspecs (`add`/`reset`/`checkout`/`rm`/`diff`) use `:(top,literal)` — paths from the repo root work from any working-directory subdirectory, and glob metacharacters in file names (`*?[]`) stay literals. Untracked files are deleted by absolute path from `repoRoot`.

**Errors:** all mutating git calls go through `runGit()` — on a non-zero exit code, the first line of stderr goes to the status bar in red (`delegate.reportError`, the same channel and life cycle as editor errors: any key dismisses it). No error is swallowed silently.

**Status view:**
- `j/k` — navigation, `Enter` — diff of the selected file/commit
- Row letter: staged section — `A` in `Theme.stagedColor` (blue1; everything in the index means "added for the next commit"), except staged deletions — those are honestly `D` in `Theme.deleteColor`; an unmerged entry (merge conflict, `UU` from porcelain) — `C` in `Theme.red` in BOTH sections: it is neither an addition nor an edit but a conflict awaiting resolution (`U` would read as unstaged); unstaged — the real worktree letter: `M` in `Theme.unstagedColor` (orange, like the gutter and the explorer), `D` in `Theme.deleteColor`; untracked — the classic dimmed `?`. The `yy` yank text carries the same letter (`GitFileStatus.sectionLetter`). Section headers — blue bold above each non-empty section, as before
- `a` — add: stages the file's worktree state (`git add`, idempotent when already staged); on an unmerged row (`C`) in EITHER section this is "mark resolved" — add writes the resolution into the index and clears the unmerged stages, the only safe action for a conflict. The cursor stays in place: the list rebuild after refresh resolves the selection (and the visual anchor) with the `SectionedListSelection` policy (SwimCore, tested) — the position follows its entry while it lives in its section, and holds the row (with clamping) when the entry moves to another section or disappears; several files in a row can be added/discarded without the cursor jumping across sections. A vanished section — index clamping (selection) / collapse onto the selection (anchor)
- `d` — drop "from where the change lives": staged section → unstage (`reset HEAD --`, a staged rename — on both sides), the worktree keeps the change; unstaged → discard (`checkout --`), untracked — delete the file from disk. The destructive half exists only where the change is NOT yet in the index — with this key staged content cannot be destroyed, discard-after-unstage is an explicit two steps (`D` is the deliberate one-press exception). Discard rewrites the file on disk — the panel calls `fileChangedOnDisk` (absolute path), and Application reloads that file's clean editor tab from disk (`BufferManager.reloadIfClean`: the tab's place, mode, and clamped cursor/scroll are preserved, undo is reset; a modified buffer is not touched — unsaved edits outrank the disk; file missing on disk — vim semantics, the buffer lives on, `:w` will recreate it), LSP gets a full didChange (contentChange without range) + a token re-request. add/unstage of a file does NOT rewrite it (index only) — no reload needed
- `D` — discard outright, bypassing the unstage half-step: the change dies wherever it lives, index AND worktree at once — the one-press exception to `d`'s staged protection (Shift as the force modifier of the family, `:q!`/`w!`). Per-status plumbing, all verified against live git: a staged plain change (M/D) restores index AND worktree from HEAD (`checkout HEAD --`: a modification reverts, a staged deletion resurrects the file; a file that is ALSO worktree-modified is wiped on both levels); an unmerged `C` row — from EITHER section, `checkout --` refuses unmerged paths — resolves the conflict to HEAD's side (the merge itself stays in progress, concluded with `c`); a staged addition and the new side of a staged rename/copy are removed from index and disk (`rm -f` — HEAD knows no such path, checkout would refuse with a pathspec error); a staged rename also restores its old side from HEAD first (the rm only runs after the restore succeeded — a failed checkout must not strand the change's only copy). Unstaged/untracked rows behave exactly like `d`. Checkouts that rewrite files notify clean tabs to reload (`fileChangedOnDisk`); `rm -f` leaves deletion to vim semantics (an open tab keeps the buffer). In the diff view `D` is a no-op — hunk-level surgery stays `d`'s
- `c` — commit window (see CommitWindow); during a merge (live MERGE_HEAD) the prefill is the message git prepared (`--git-path MERGE_MSG`, "Merge branch 'x'"; `# Conflicts:` comments are cut out) — completing the merge is edit-and-save; pressing `c` again while the window is open — refocus without clobbering the text
- `C` — commit window prefilled with the last commit's message (`git log -1 --format=%B` — subject + body, not just the subject from the log list): handy for a series of commits on one task. The text is inserted as the initial content (no undo record, not modified), the cursor at the end. Empty history (a fresh repository) — just an empty editor, the `c` behavior
- `A` — amend HEAD: the commit window with the last commit's message (exactly what `git commit --amend` would show in the CLI editor) and the `Amend @ <hash> branch` plate — the target commit is named while typing (the hash rides the existing HEAD verify probe, truncated to the panel's 7-char convention); `:w` runs `git commit --amend` — HEAD is rewritten with the staged state + the edited message, the same runGitCommand funnel (output/errors visible, the post-finish service free). Refused upfront wherever git itself would refuse, so the status bar says so BEFORE the typing (the commit funnel closes the window when `:w` fires — a late git refusal would eat the typed message): no HEAD (a fresh repo has nothing to amend) or an in-progress merge/cherry-pick/revert — the operation that owns the next commit (`c` concludes each of them). A rebase `edit` stop is deliberately not blocked: amending there is the standard rebase workflow. While composing, the latest explicit intent wins: `A` after `c` flips the session to amend (and `c` back) with a freshly captured target hash, the typed text is never clobbered, only the plate retitles
- `p` / `P` — globally: `git pull` / `git push` are now `Ctrl+O` / `Ctrl+P` from any window (the same `runGitCommand` funnel: output and spinner go to CommandWindow; if the remote asks for credentials — input in the CommandWindow command line, see Core/InteractiveShell.swift); the local `p`/`P` were removed from the git panel
- `yy` — copy the status row (OSC52), `V` — visual selection of entries
- `Escape` — close the panel

**Diff view:**
- `j/k` — line navigation, `a` — stage the active hunk (a patch from the diff header + the hunk's lines → `apply --cached`; the index — the file is not touched, the editor buffer stays current; on a staged-diff — a quiet no-op), `d` — drop the hunk "from where it lives": staged-diff → unstage (`apply --reverse --cached`, the worktree keeps it; a full discard — a second `d` from the unstaged-diff), unstaged-diff → discard (`apply --reverse`, success → `fileChangedOnDisk` → clean tab reload), untracked — file deletion
- `yy` / `V`+`y` — copy lines, `Escape` — back to the status view (from visual — exit visual first)

An open file diff is re-requested on every refresh result — `reloadOpenDiff(afterRefresh:)` in `poll()`: a branch switch, pull, or terminal command will not leave stale lines. The panel's hunk actions restart the diff themselves and immediately (spinner in the same frame, hunks are cleared synchronously — a double press will not find a hunk to act on twice); there is no double render: a monotonic request-clock orders the two pipelines — a refresh does not reload a diff requested after its start (that one is fresher by definition). A commit diff is addressed by hash and immutable — not re-requested; an emptied diff (the file became clean) closes itself; an untracked file that disappeared from the status closes the view immediately — `git diff --no-index` on a missing file answers with an access error, not an empty diff.

The diff is highlighted: green — additions, red — deletions, cyan — hunk headers. On the left — a gutter with line numbers in the editor's style: the shared primitive `Window.drawLineNumberRow` (a right-aligned number in the first `width-1` cells + a trailing slot — a space or the caller's mark; width `max(4, digits+2)`) draws both the editor gutter and the diff gutter — no code duplication (only the editor uses the mark — diagnostics dots). Numbers are computed from unified diff counters (`@@ -a +c @@` seeds both) and only inside hunks — commit message lines like `+1 fixed` do not count as content: `+` lines carry the new file's number (in green), `-` the old one's (in red), context — shared (dimmed); `@@` headers, `+++`/`---`, and commit metadata — no number. Combined diffs of merge commits (`diff --cc`, `@@@` headers with two parents and two-column line prefixes) do not fit the two-counter model — their hunks get no numbers; an honest nothing is better than wrong. The number color does not change on the cursor row — the row highlighting already marks the current one. The raw `diffLines` are untouched — yank and gutter patch assembly do not see it. All panel headers (branch/loading/visual/diff with hints) — through the single `HeaderPlate` mechanism; long paths are truncated to the window width (`drawHeader` uses `prefix(width)`).

Any completed git command (`pull`/`push`/`commit` — `gitCommandFinished` from CommandWindow) restarts `fetchGitStats` (a commit clears staged marks and the gutter's per-line colors), updates the panel, and does an **mtime-sweep** of clean tabs (`BufferManager.reloadChangedOnDisk`): a merge during pull could have rewritten open files — the mtime differs from the one recorded at open/` :w`/reload → reload; identical content → only the mtime is updated (undo is not reset). The same sweep — after a command in the built-in terminal (`terminalCommandFinished`: for example, a manual `git checkout`). The panel's own mutations (stage/unstage/discard of a file and a hunk) call `gitWorktreeChanged` after `refresh()` — Application restarts the same fetch, updating the editor's git gutter and the explorer's marks. After list rebuilds the selection (`selectedSection`/`selectedRow`) is re-resolved by the `SectionedListSelection` policy inside `rebuildStatusList()` (called from `poll()`). When the panel is reopened, the diff view resets to the list (`closeDiffView`) and the body is cleared (`prepareOpen`): in flight — an empty body and a plate without the "@ branch" (no spinners/"loading" — even a transient indication is visible to the eye); the missing content appears in a single frame when the fetch lands. In-place refreshes `a`/`d`/completed commands do NOT clear the panel — an in-place update does not count as a jump. The remaining gap in the family: edits outside swim (sed -i bypassing the app) — a file-watcher/focus-time check is needed, separately.

All git operations go through `Shell.git` (a `/usr/bin/git` subprocess, arguments passed as an array — quotes and Cyrillic in paths/messages are safe).

---

### Window/GitBranchesWindow.swift — Branch Picker

Branch picker: opened globally with `Ctrl+B` (toggle: closed/open; reopening — a freshly loaded list, menu mode, cursor on the newest branch). The model is like search results, but with two input surfaces over one list: `.insert` — typing the filter or (`a` in the picker's menu, the branch creation phase) the new branch's name in the window's own input row (row 0; the caret is a terminal bar cursor via the shared factory `CursorRenderInfo.insertCaret`, one for all input surfaces — the editor's insert, the command line, the search/picker/terminal prompts; normal mode does not own the terminal cursor — the renderer resets the shape to a block; the visible text portion and the caret column are computed via the shared pure policy `InputLine` — SwimCore, tested), `.menu` — navigation; `.command` — the standard `:q`.

**Data (paginated, git does everything — sorting, searching, and the limit):** `git for-each-ref --ignore-case --count=<limit> --sort=-committerdate --format=%(refname:short)%00%(committerdate:relative)%00%(HEAD)%00%(refname) [patterns]` — sorting by last commit date and page counting are done by git itself (swim neither sorts nor filters; local and remote branches come in one committerdate order), the current branch is recognized by `%(HEAD)` = `*` and drawn bold green with a `*` marker; on the right, in a dimmed column — the commit's relative date; remote-tracking entries (full name `refs/remotes/…` — the 4th NUL field) — in dimmed `Theme.comment`: this is not the working set yet, there is no local copy; the symlink `refs/remotes/<remote>/HEAD` (a pointer to the remote's default branch, not a branch) is excluded. Parsing — the pure parser `BranchList` (SwimCore, tested): lines by `\n`, fields by NUL; an empty HEAD flag on non-current branches must not break field counting. Not a repository (non-zero exit) — a distinct "Not a git repository" state, different from an honestly empty list.

**Paging:** a page is 20 entries (`--count`); when the cursor gets within 5 rows of the loaded page's end (the 16th row of 20), the limit grows by a page and the list is re-requested wider — the branch table is read exactly as deep as the user actually went. A short page (fewer than requested) — git exhausted the matches, "no more"; the flag is compared against the limit at request time so that page growth during the flight does not falsify it. The indicator — a trailing "… more" / "… loading" under the list (there is no branch counter in the plate).

**Search goes to git with every character** — the cache is not reused: the first page of matches for a longer query is NOT a subset of the on-screen page (the newest `fix*` may contain not a single `fixe*`), so every edit of the query restarts for-each-ref with the new pattern; the newest-wins `BackgroundTask` collapses a fast-typing queue into the last request. Patterns are built by `BranchList.matchPatterns` (SwimCore, tested): an empty query — locals only (`refs/heads/` — the unfiltered table is the working set); non-empty — both spaces: `refs/heads/**/*<query>*` + `refs/remotes/**/*<query>*` (a branch pushed to a remote without a local copy — exactly what is being searched for; a local duplicate suppresses its remote rows — Enter on the local one is the same switch, and `D` already covers the remote side; a remote twin without a local one stays on every remote where it lives; `Enter` on such a row switches by name without the remote prefix, git-DWIM creates a local tracking branch — the manual `git switch <name>` flow; `d`/`D` on a remote row refuse with a message — deleting the remote side is `D` on the local branch) — `**/` crosses path component boundaries (a single `*` in WM_PATHNAME would not see nested `feature/x`), the query's slash stays a literal ("feature/t" matches "feature/two-fix"), the query's glob metacharacters are escaped (`\*?\[]`), case-insensitivity — via native `--ignore-case`.

**Keys:** the insert phase owns neither the selection nor the action keys: `↑`/`↓` and `Enter` ("search finished", the filter is kept) move it to menu mode, placing the cursor on the first row (the next press moves from there); `Esc` in insert — the same plus a filter reset (the list is re-requested without a pattern via the same path as manually erasing the query), `Esc` in menu — closing; `i` — back to typing (cursor at the end). In menu, `Enter` — `git switch <name>` through the single `runGitCommand` funnel (CommandWindow shows the output/errors — for example, a dirty-tree refusal; its `gitCommandFinished` does all the post-switch service: fetchGitStats, panel refresh, mtime-sweep of clean tabs — switch rewrites files); the picker closes before launch, Enter on the current branch — a no-op with a message; `Ctrl+Enter` — the same + `git pull` right after (on the current branch — just pull): mainstream terminals send Ctrl+Enter as LF (byte 10) — a byte twin of Ctrl+J, without any keyboard protocol negotiations; the byte is intercepted only in the menu phase, insert silently ignores it. `a` in menu — branch creation: the input row becomes a name prompt (` New branch: `), the name starts as the current filter (typed a name, found no branch — `a` keeps what was typed), name edits do not re-request git; `Enter` — `git switch -c <name>` through the same runGitCommand funnel (creation + switching in one move; output/errors visible, the post-finish service is free), `Esc` — back to the list, the filter untouched: the name lives in a separate buffer, not in the filter. `m` in menu — merge into the current branch: the input row becomes ` Merge branch: ` taking `<name> [arguments…]` — the first token is the ref, the rest pass through (`side --no-ff` works verbatim); the invocation is rebuilt as `git merge <args> -- <name>`, so user flags stay flags and a leading-dash name stays an operand, validity is git's problem (visible errors). A conflicted finish is not an error but a state: CommandWindow detects unmerged entries (`ls-files -u`) and holds a modal one-key choice — `k` keep for manual resolution (then commit from the git panel), `o`/`t` abort and merge again with `-X ours/theirs` (the user's arguments are preserved in the retry), `Esc` — `git merge --abort` (see the key table below). `d`/`D` in menu — branch deletion (see the key table below): through the same runGitCommand funnel, the picker does not close — the finished command refreshes the list itself. The chain is executed by CommandWindow (`runCommand(then:)`): the follow-up starts only after the first command completes SUCCESSFULLY (after its `gitCommandFinished` — the world is already refreshed), on failure or an Esc-cancel it is quietly dropped — the first command's output stays on screen with an explanation. Selection policy: the insert phase does not own the selection — the index sits on the first row, and every fetch of the input phase (filter edits, Esc-reset, a fresh open) lands there too; the branch name via reload is kept only by menu-phase fetches (page growth, external refreshes — `gitCommandFinished`). The intent is captured at request time and travels with the result (`BranchFetch.keepsSelection`), like the pattern and the limit — the mode may change while the request is in flight, the result does not obey it.

**Integration:** its own slot in the bottom stack (git → branches → command window → terminal; the same `min(25, h/2)` and waterfall trimming, `Ctrl+S` — half the height); the spinner ticks in the shared `tickSpinners` — its anyDirty block also consumes landed background results (`pollWindows`) and renders them while idle, without waiting for a key; a completed git command refreshes the list while the picker is open; entry — only the global `Ctrl+B` (intercepted from any window, including the terminal, consistent with the other toggles): all branch operations live here, the git panel does not duplicate them.

---

### Core/InteractiveShell.swift — Interactive subprocess (pull/push credentials)

`InteractiveShell` — a subprocess with a live reader thread: the form that `git pull`/`push` require when the remote asks for credentials. Replaces `BackgroundTask` in CommandWindow (but not in the other windows — they do not need prompts).

**Mechanics (GIT_ASKPASS):** the session points `GIT_ASKPASS`/`SSH_ASKPASS` at a once-per-user generated helper in the system temp dir (`FileManager.default.temporaryDirectory` — /tmp on Linux, $TMPDIR on macOS; name `swim-askpass-<uid>.sh`, mode 0700):

```sh
#!/bin/sh
printf '%s\n' "$1" >&2                          # the prompt — swim detects it in stderr
[ -n "$SWIM_CRED_FIFO" ] || exit 1              # the guard — no FIFO (a degraded start), fail fast
IFS= read -r ans < "$SWIM_CRED_FIFO" || exit 1  # the answer — from the session's per-session FIFO
printf '%s\n' "$ans"                            # the answer git reads from stdout
```

askpass is invoked by git with the prompt in `$1`; the prompt reaches swim through each helper's inherited stderr, but **the answer cannot travel over the session's stdin**: for HTTP(S) remotes the credentials are requested by the transport helper `git-remote-https`, whose stdin is the protocol pipe to the parent git (an askpass inheriting it reads protocol garbage, and writing into a stdin nobody reads hits EPIPE); askpass for ssh gets `/dev/null`. Therefore the answer channel is a per-session FIFO (`SWIM_CRED_FIFO`, name `swim-cred-<pid>-<uuid>.fifo` in the same system temp dir, 0600, unlinked on EOFs), opened by the session O_RDWR in advance: the open does not block, a written line is buffered until a reader arrives, EPIPE is impossible while the session holds the descriptor (it is itself the reader). The password never touches disk or `/dev/tty` (the raw terminal stays with swim, git's own tty-prompt is not enabled — askpass takes priority). `SSH_ASKPASS_REQUIRE=force` — OpenSSH >= 8.4 asks for the password through the helper even with a tty; the ssh scenario works fully (stdin for the helper is no longer needed).

**Reader thread:** non-blocking reading of both pipes in one thread (sequential blocking is the classic two-pipe deadlock, two threads — more coordination); EOF on both → unlink the FIFO → the output is published to a mailbox; the exit code is collected by the owning thread in `consumeResult` (the process is dead by then, `waitUntilExit` is instantaneous — the reader does not touch Process, which is not Sendable, and its internal reaper owns waitpid). Prompts are detected by full stderr lines: `Username for '…'` → login, `Password for '…'` / the suffix `password:` / `Enter passphrase` → password; lines with the prefixes `fatal:`/`error:`/`remote:`/`warning:`/`hint:` are excluded — an auth failure does not re-arm the prompt, and remote sideband output cannot sneak in a fake one (a real askpass echo arrives without a prefix).

**Concurrency model:** the session object is not Sendable and main-thread-confined — it owns the `Process` and the FIFO descriptor as plain stored properties, and the compiler guarantees that. The only cross-thread state is `Mailbox`: a small `@unchecked Sendable` class whose state (prompt/cancelled/done/stdout/stderr) lives in SwimCore's `Locked<State>` — an NSLock cell (`Synchronization.Mutex` would need macOS 15 while the package ships 13; the `@unchecked` vouch is the same one `LSPClient`/`BackgroundTask` make for their `Locked` mailboxes — every access is behind the lock). The reader thread captures only Sendable values — a reference to the Mailbox, raw fds, the FIFO path, never `self` or `Process` — so the read loop cannot be broken off by the session's dealloc and always runs to the reap/unlink.

**UI contract (CommandWindow):** prompt → the window's `enterCommandMode()`; the mode label in the status bar via the overridable hook `Window.commandModeLabel()` — `LOGIN`, then `PASSWORD` (`PASS` on narrow screens, < 45 columns), the same orange badge; a non-empty hook also removes the `:` prefix — the surface is entering a credential, not a `:`-command. Plate: `⠏ git push — waiting for password`. Enter sends the line into the FIFO (`answer`), **Esc — cancels the whole operation** (`cancel()`): the FIFO is closed (every blocked askpass reader dies, releasing the inherited descriptors) + SIGTERM to the process — the operation dies rather than hangs; the final plate says "cancelled". The same cancellation covers closing the window (`Application.closeWindow` → `cancelPendingCredential`) and re-running a command over a hanging prompt; closing the window during a normal (promptless) run does not touch the process — the previous behavior.

The password is never echoed in the clear: `masksCommandLine()` (CommandWindow) makes the status bar render asterisks of the same length — the login stays visible. **Known limitations:** the prompt pops up only in the current space (polling goes over `spaces.current` — like all background tasks: a delay until returning from the search space, not a deadlock).

---

### Core/PipeWriter.swift — EPIPE-tolerant pipe writing

The single form of writing to children's stdin/FIFO (`LSPClient` frames, `Shell.run` stdin, `InteractiveShell.answer`): a raw `write(2)` loop — EINTR is retried, partial writes are completed, any hard error stops the loop silently and is returned as a Bool (`writeAll` → false). `FileHandle.write` is unfit for this: corelibs wraps the syscall in `try!`, and any return error (EPIPE first of all — the child died between the liveness check and the write) kills the whole process (`Foundation/FileHandle.swift:709`, verified on the main thread and a dispatch queue). The truth about liveness belongs to the caller's state machine: `LSPClient` marks the client dead on an undelivered frame (a half-open server — stdin closed, stdout held up — would otherwise sit isReady forever, silently swallowing frames), `Shell`/`InteractiveShell` own their liveness and ignore the result. The signal half of the policy is set by `main.swift`: `signal(SIGPIPE, SIG_IGN)` process-globally — otherwise the error arrives as a signal (exit 141), and no return-error handler can catch it; neither Dispatch nor Foundation Process/Pipe sets this ignore on Linux (verified), previously it was only inherited from the parent shell. Children inherit the ignore: built-in terminal pipelines see EPIPE returns instead of death by signal — the same price any editor on a SIGPIPE-ignoring runtime pays.

---

### Window/SearchResultsWindow.swift + PreviewWindow.swift — Project Search

A pair of windows in the `search` space: on the left — the results as a FULL TREE from the working-directory root (the pure SwimCore `SearchTree.build`): one expand/collapse level per path component, root → … → directory → file → match lines — the whole path of a nested file is visible, shared ancestors merge into one node (the old single-level "immediate parent → file" grouping hid the chain and made same-named directories at different depths indistinguishable); on the right — a preview of the selected file with the active line highlighted.

**Query input:** the input phase is the window's insert mode (`inputMode` — derived from `mode == .insert`); on entering the space (Ctrl+F) the panel takes text immediately, and `:` is typed literally then. Navigating the results is menu mode; `i` returns to the query input — a NEW query from an empty line (the branch picker's `i` keeps its filter; a search query is a fresh search, not a view tweak — the deliberate difference). `Escape` closes the space from EITHER mode — one key, one meaning.

**Session restore (`reopen`):** the window instances live for the whole app session, so the tree, expansions, and cursor already survive a close; `reopen` decides what to show. With session state (a completed search this session) the space reopens straight into MENU mode — the saved tree, cursor, and expansions — the first open of a session lands in the query input (with the editor's last `/` query pre-running, as it always has), and a scan still in flight reopens into the scanning plate its result will land into. The two-row plate carries the query and the count with the git panel's `key: action` idiom — ` Search "query" ` over ` N matches (i: new search) ` (narrow panels truncate tails; the query and the count lead their rows).

**Per-file freshness (event-driven, no loops):** the scan fingerprints every matched leaf (size+mtime at read time). A file-change event the app already has — an editor save, a rewrite the tab-mtime machinery detected — reaches `refreshFileIfInSession` behind an O(1) guard (the space must be open and the file a leaf; a rebuild nobody watches is idle work), which re-reads and re-searches ONLY that file, never the repository. Reopen runs the complementary walk: every leaf is stat-checked against its fingerprint — unchanged files cost microseconds and nothing runs; changed files (including external edits no event ever saw, and deletions) are re-read by one background pass whose landing rebuilds the tree IN PLACE: expansions survive by their path keys, the cursor follows its file anchor (clamped when the file's matches are gone), and emptied branches collapse by construction — `SearchTree` materializes directories only on paths to matched files, so a file losing its last match takes its ancestor chain with it, no pruning pass. During that restore-time pass the STALE tree is not shown (showing it and rebuilding a beat later would visibly jump the cursor) — the body stays blank for the milliseconds the refresh takes and the landing reveals the fresh tree in one frame; the plate deliberately keeps its last count until that frame (a transient `refreshing` label would flicker). The single-slot task deduplicates a live trigger against a reopen walk over the same file, and a refresh computed before a newer search is dropped at its landing (the epoch guard — the two tasks hold independent slots, and newest-wins works within a slot, not across). Files that never matched stay outside the walk — brand-new matches need `i`+Enter; same-second same-size edits are beyond any mtime scheme without a watcher (which the app deliberately does not run). The preview applies the same fingerprint idea to itself: `loadFile` stats the file, keeps the session when the stat is unchanged (cursor movement never re-reads), re-reads on change, drops the session for an unstattable file.

**Search (`search(query:in:)`):**
- Recursively walks all files in the directory
- Excludes: `.git`, `node_modules`, `.build`, `build`, `DerivedData`
- Skips binary files by extension (png/jpg/jpeg/gif/pdf/zip/gz/o/so/dylib/a)
- Line-by-line case-insensitive search

**Result structure:**
- `SearchResult` (SwimCore) — filePath, lineNumber, lineContent, matchStart, matchLength
- `SearchTree.build` — the tree: read-only nodes after the build, dictionaries index the insertion (O(total), like the old flat grouping), every level sorts directories before files (the explorer's ordering), a directory's `matchCount` is its subtree total folded bottom-up (the root's total always equals the flat count — the header and the root row cannot disagree)
- The scan result carries its own root (`(root, results)` rides the `BackgroundTask` payload): the mailbox may be consumed long after the search started — polling runs over the current space, so leaving the search space defers the pickup — and the tree is always built against the directory that was actually scanned, never a separately stored path
- Expansion state lives in the window as path-keyed sets (`expandedDirs`/`expandedFiles`), NOT on the nodes: the tree is rebuilt on every search, path keys survive the rebuild — what was expanded stays expanded for the results that return
- After a search completes, the tree lands COLLAPSED on its root row (`pollSearch` resets cursor and scroll — a fresh result set is a fresh navigation session); nothing auto-expands — the user opens the nodes they need

**Rendering:** depth-based indents (`depth * 2` cells — a file one past its directory, a match line one past its file), directory rows blue bold with the subtree count, file rows dim with the line count, match rows `N: …` with the match in orange. Rows go through the shared cell pipeline (`Window.textCells` to assemble styled cells, `Window.drawCells` to paint the horizontal-scroll window — the same pipeline the explorer's rows use): every grapheme takes `displayWidth` cells with a `wideContinuation` cell for wide glyphs (CharWidth — the single width authority; CJK/emoji in file names and matched lines otherwise shift the row by a cell per glyph), and the scroll bound (`maxVisibleContentLength`) counts cells the same way (`Window.cellCount`). The before-match width math is clamped at zero: a match longer than the window draws from its start truncated by the cell bounds — `String.prefix` traps on a negative length, and a deep indent plus a long query in the narrow panel made the old unclamped arithmetic reach it (a 20+ character query at the default panel width crashed the render loop).

**Preview highlighting (`Highlight.Session` — SwimCore, tested):** the preview panel colors the file it is showing — lazily, in every dimension: only the currently previewed file (nothing pre-colored), only the visible lines (one window-shaped `tokens()` call per draw; markdown's tokenizer is viewport-based, code/JSON loop lines inside), and the cross-line state (multi-line strings, fenced blocks) is carried by caches that never invalidate — the preview's content is an immutable snapshot, sealed inside the session (the PieceTable is private; callers see a read surface only, so no code can break the caches). Language routing mirrors the editor's builtin layer minus LSP: `json` → the JSON tokenizer, `md/markdown/mdx` → the markdown tokenizer with its viewport cache, anything else → the lexical tokenizer with the language profile by extension (same functions the editor calls — coloring parity holds by construction). The color policy is a DIM overview with the lexical types colored — keywords, strings, numbers, comments (`Theme.color(forToken:)` is the single type→palette map shared with the editor; the preview keeps a deliberate subset, everything else stays in its dim base). Files past the editor's 50000-line guard render plain, mirroring the editor's builtin bound. Preview rows render through the shared cell pipeline too (token runs as `textCells`, clipped by `drawCells`) — wide glyphs in previewed content align as everywhere else.

**List consistency (`ensureFlatItems`):** the flat row list is rebuilt lazily through one funnel — the renderer and every list-reading key handler (`j`/`k`/`Enter`/`h`/`l`) pass through it, so every consumer bounds-checks against the CURRENT list (a `j` after an Enter-collapse, bound-checked against the stale longer list, could step the selection past the real end — an invisible, silently drifting cursor). The branch row an action acts on persists through the rebuild (only its children vanish below), so an index pointing at a branch stays valid across it.

**Controls:**
- `j/k` — navigation
- `Enter` — the explorer's activateCurrent: on a match line opens the file; on a directory/file row toggles it — expanding descends to the first child, collapsing keeps the row
- `l/Ctrl+Right (Ctrl+L)` — the explorer's selectCurrent: never collapses — a collapsed row expands and descends, an expanded one just descends; on a match line opens the file. The descend itself is the shared `TreeListNavigation.firstChild` policy — the same rule the explorer's `descendToFirstChild` runs on
- `h/Ctrl+Left (Ctrl+H)` — collapse like the file explorer (the shared `TreeListNavigation.collapseTarget` policy): the key acts on the selected row's PARENT branch — the nearest row above one depth shallower — selecting it and collapsing it; on a match line this folds its file's lines, on a file — its directory, on the root — the whole tree (a second press is a no-op). Expanding is `l`/Enter's job; `h` never expands
- `i` — to the query input, a new query from an empty line (the vim insert idiom)
- `Escape` — close the search space, from either mode (menu or input) — one key, one meaning
- `left/right` — horizontal shift of result lines (step of 4, for viewing long lines)

---

### Window/TerminalWindow.swift — Built-in Terminal

Terminal panel (Ctrl+T or `:terminal`/`:term`/`:sh`): type shell commands and view output without leaving the editor. At the top — a fixed full-width `Terminal @ folder_name` plate (the working directory) via the shared `Window.headerPlate` mechanism (content below is computed from `contentTop`/`contentHeight`), below — the output history on the dark-gray `Theme.terminalBg` background, distinct from the background of the other windows.

**Input:** a live `>` prompt — the last line of the scrollable buffer, there is no fixed input line. Line editing (`left/right/home/end/backspace/delete`), `Ctrl+Left`/`Ctrl+Right` — command history, `Tab` — path completion (a single match is substituted in full, for directories with a `/`; several — the common prefix), `Enter` — run.

**Output scrolling:** `up/down` — line by line, `Ctrl+Up/Down`, `PageUp/PageDown` — a page, `Ctrl+D/U` — half a page. After `Enter` the view is placed on the executed command — it is the top row of the window, the result reads top-down without manual scrolling; the output itself does not move the view. Typing any character, `Enter`, `Escape`, or switching history (`Ctrl+Left/Right`) returns the view to the live prompt.

**Running (`submit`):** each command runs as its own `/bin/sh -c` (pipes, `&&`, environment variables work) in the background via `BackgroundTask`; a spinner spins in the prompt. Output: stdout — in the normal color, stderr — in red, and on a non-zero exit code a `[exit N]` line is added. The output buffer is capped at 10,000 lines (older entries are evicted). After any command completes, the window calls `terminalCommandFinished` on the delegate — Application restarts `fetchGitStats` (the branch/diff in the status bar may have changed: a file edited, renamed, branch switched) and `gitPanel.refresh()` (the same contract as git commands from CommandWindow).

**Special commands:** `cd <dir>` — changes the window's working directory (each command lives in its own sh, so the window itself tracks the cwd; `~` and relative paths are supported), `clear`/`cls` and `Ctrl+L` — clear the output, `exit`/`logout` — close the terminal window (`requestClose` on the delegate; the window hides, the history is kept until the end of the session).

While the terminal is focused, `:` and `Tab` go into the command being typed — the application command line and the focus cycle do not intercept them.

---

### Window/StatusBarWindow.swift — Status Bar

A single-line panel at the bottom of the screen:

**Left part:** the colored mode badge — the mode source is the command line's owner window, otherwise the focused window (MENU=blue, NORMAL=blue, INSERT=green, VISUAL/V-LINE=purple, COMMAND=orange). The source is set via the weak `commandSource` reference — the status bar itself reads the mode, the command-line buffer, and its cursor position from it, which it serves as the terminal bar cursor via `cursorRenderInfo()` (overriding the editor cursor — input surfaces are mutually exclusive by the focus rules). While the owner window is collecting a credential, the `commandModeLabel()` hook returns LOGIN/PASSWORD instead of COMMAND (PASS on narrow screens) — CommandWindow, see Core/InteractiveShell.swift. The status bar resynchronizes after every key — a focus change (panel toggles, Tab, space switch) is reflected immediately.

**Center:** precedence — the error text, then in COMMAND mode `:<command>`, then the diagnostic under the cursor (`cursorDiagnostic`), otherwise the git branch and the total `+N -M` added/removed lines of the working tree (`git diff HEAD --numstat` — a background task without a debounce: save/open/tab-switch/git events refetch it directly; the only 0.3s debounce in the app is the LSP token re-request; green/red). Outside a git repository the center is empty.

**One fetch — three consumers:** the same background task (`gitStatsTask` — a newest-wins `BackgroundTask`: a start while a fetch runs queues the latest request and drops the superseded result) computes the git decorations alongside the status-bar numbers: the active file's per-line status (`HunkLines` over `git diff -u0` / `--cached -u0` → `GitLineStatus` onto the tab; the pathspec — the path resolved through symlinks, relative to the resolved repo root) for the gutter's number coloring and the explorer's file-name marks (`Porcelain.parse` + `GitChangeClass` → `[path: class]` in the tree's coordinates). `pollGitStats()` distributes the results: the status bar gets the numbers, `editor.applyGitLineStatus` — the gutter (by path, the tab may have switched), `fileExplorer.setGitMarks` — the explorer. Fetch triggers: startup, `fileSaved`, `activeFileChanged`, `gitWorktreeChanged` (panel stage/unstage/discard, explorer create/delete/rename), opening the git panel, `gitCommandFinished`, `terminalCommandFinished`, mtime-reloads.

**Right part:** file type, `+N -M` for the current file (from the same numstat, updated after saving), encoding, `line:column`, percentage position in the file

---

### LSP/LSPClient.swift — LSP client

Language Server Protocol client for semantic highlighting and go-to-definition. Supported servers (`Application.setupLSP` searches standard paths + `which`):

- **Swift** — sourcekit-lsp
- **C#** — OmniSharp
- **Go** — gopls
- **Rust** — rust-analyzer
- **Bash** — bash-language-server (`start`)
- **Python** — basedpyright-langserver (`--stdio`, `pip install basedpyright` / `uv tool install basedpyright`). pyright is excluded: it does not implement semantic tokens; basedpyright supports both highlighting and `gd`. Module search paths: `[tool.basedpyright]/[tool.pyright].extraPaths` and `pyrightconfig.json` are read by the server itself (relative ones — from the project root; the client has no access to extraPaths settings). When there is no server-side configuration, swim sends the `pyright` section via `workspace/didChangeConfiguration` with a base like pyright's: `typeCheckingMode: standard` (basedpyright's own default is `all`, whose reportUnknown*/annotation rules flood the diagnostics with useless warnings) and `diagnosticMode: openFilesOnly`; when a server config exists swim sends nothing — the project config wins. For basedpyright, `initializationOptions` is not a settings channel (only `disablePullDiagnostics`)

**Protocol:** JSON-RPC 2.0 over stdin/stdout with `Content-Length: N\r\n\r\n` framing.

**Life cycle:**
1. `start()` — launches the server as a subprocess via `Process`
2. `sendInitialize()` — sends `initialize` with capabilities (semantic tokens full, `publishDiagnostics`). sourcekit-lsp 6.2+ strictly decodes capabilities per the LSP 3.16 spec: `publishDiagnostics` must be a `PublishDiagnosticsClientCapabilities` object, not a bool (a bare `true` made initialize fail with -32602 — python worked, swift stayed silent; basedpyright is lenient about the form). Exactly what the client uses is declared: semantic tokens — full requests only (delta is not requested, `handleSemanticTokensResponse` decodes only the `data` form); `tagSupport: [1]` — exactly the Unnecessary tag that `decodeDiagnostic` renders (servers do not send tags outside the declared set); `versionSupport` — with it basedpyright attaches a `version` to the publication, which the freshness guard in pollLSP compares with `lastSentVersion(uri)` (sourcekit-lsp does not send a version — the guard treats a missing version as fresh)
3. `handleInitializeResponse()` — extracts the token legend, sends `initialized`, replays deferred `didOpen` (an array deduped by uri — opening a second file before initialization does not swallow the first; reopening replaces the text). An error response (rejected handshake) marks the client dead (`alive = false`, like the EOF branch): the server process often keeps living, never initializing, and its silence is no longer masked by an eternally "alive" server; on the next edit notifyLSPChange removes such a client from `lspClients`, first `stop()`-ing the process (an explicit SIGTERM + cancellation of the read source instead of implicit cleanup by the Pipe destructor)
4. `openDocument()` — sends `textDocument/didOpen` (the version is assigned by the client) + requests semantic tokens
5. `changeDocument(changes:)` / `reloadDocument(text:)` — incremental / full `textDocument/didChange`; document versions belong to the client (`documentVersions`): per-document, strictly increasing, surviving tab reopening — a late `publishDiagnostics` from a past incarnation does not pass the guard
6. `handleSemanticTokensResponse()` — parses the LSP semtok protocol (tuples of 5 ints) → `[SemanticToken]`
7. `handleMessage()` on `publishDiagnostics` — decodes `LSPDiagnostic` (range, severity, tags) into `diagnosticsMailbox`
8. `Application.pollLSP()` — drains mailboxes on every loop tick; for diagnostics it compares the publication's `version` with `lastSentVersion(uri)` and discards stale ones, putting current ones into `EditorBuffer.diagnostics` via `applyDiagnostics`

**Asynchrony (single-owner confinement):** all protocol mutability (`buffer`, `pendingRequests`, legend, `initialized`, `documentVersions`, the deferred didOpen queue) belongs to the client's serial queue; frames are serialized on the calling thread and leave the queue as whole `Data` — FIFO of `Content-Length` frames is guaranteed in both directions, dictionaries never cross the thread boundary. Frame writing — `PipeWriter.writeAll` (an EPIPE-tolerant `write(2)`): a server that died between the `alive` guard and the syscall does not take the editor down (via `FileHandle.write` — fatal, see PipeWriter); death is established by the reader's EOF branch, and an undelivered frame marks `alive = false` itself (a half-open server does not sit isReady forever) — the next edit removes the client via `stop()`. A dead client (`alive == false`)'s document methods (`openDocument`/`changeDocument`/`reloadDocument`) and `sendRequest` do nothing — no idle versions in `documentVersions`, no eternal slots in `pendingRequests`. Callback registration and request writing — one serial block: a response physically cannot be parsed before the registration (previously registration ran from main and raced the reader's `removeValue`). The main loop reads only three `Locked` cells (`tokensMailbox`, `definitionMailbox`, `diagnosticsMailbox` — a SwimCore primitive, a lock cannot be "forgotten") and the version mirror; `alive` is the single deliberately unlocked word-sized flag. Actors were rejected: the consumer is synchronous (the editor's event loop), synchronously awaiting an actor is a deadlock, and a `Task`-per-chunk does not guarantee frame FIFO.

**Diagnostics:** `EditorWindow.rebuildLSPIndexes()` (the same events as `tokenIndex`: applying tokens, activating a tab, `bufferReloaded` on an in-place reload) converts raw UTF-16 ranges into per-line grapheme spans in `diagnosticsIndex`. Rendering: the line number is no longer colored by severity — after the number, a small dot mark is placed in the gutter's trailing cell (red error / orange warning / yellow info; error+warning — a small square in the worse severity's color, see EditorWindow), spans are underlined (SGR 4), diagnostics with the Unnecessary tag (unused imports) render in gray instead of underlining — the standard convention. The status bar shows `cursorDiagnostic()`: a pure `diagnostic(at:col:)` query picks the span under the cursor (zero-width ones normalized to unit width), then distance, severity, position — a second problem on a line is shown when hovering exactly over it.

**Incremental sync:** every buffer edit is recorded as `(offset, replaced, inserted)` (hooks in `recordAction`/`applyInverse`/`applyForward` — covering edits, `:s`, and undo/redo). `EditorWindow.trackLSPChange()` converts the byte-offset to LSP positions `(line, character)` in UTF-16 code units (`PieceTable.utf16Col()` — a walk over the line's cached `[Character]`) and invalidates the inter-line states of lines from the edited line (the anchor — the edited line from the offset, not the cursor: undo/redo edits far from the cursor). `Application.notifyLSPChange()` sends the accumulated changes as one `didChange`; for files without an LSP server the queue is dropped.

**Encodings:** internally the buffer is stored as UTF-8 bytes + a per-line grapheme cache `[Character]`. LSP works in UTF-16 (the protocol default): outgoing positions are converted when writing a change, incoming token positions are converted UTF-16 → graphemes via prefix sums when building `tokenIndex` (correct for emoji/CJK).

**Limitation:** for files >5MB `didOpen` is not sent (the full text at open is too large). The guard covers only didOpen — `notifyLSPChange` has no size check, so subsequent incremental `didChange` for such files is still sent (for a document the server never saw opened).

---

### SwimCore/SemanticToken.swift — LSP data types

Defines shared protocol value types (all Sendable — they cross threads via LSPClient's mailboxes):
- `SemanticToken` — a token (used by both LSPClient and SyntaxTokenizer)
- `LSPTextChange` — an incremental change (line/char in UTF-16)
- `LSPDiagnostic` — a `publishDiagnostics` record (range in UTF-16, severity, Unnecessary tag)
- `LSPDefinition` / `LSPDefinitionResult` — the textDocument/definition result

LSPClient uses raw `[String: Any]` dictionaries for JSON instead of Codable types for simplicity.

---

### App/Application.swift — Main Controller

The orchestrator of the whole application. Manages the main event loop, window spaces (`Spaces`), the window stack, layout, global hotkeys, LSP, and rendering. Implements `WindowDelegate` — all windows report events to it.

**Main loop (`run()`):**
```
setup terminal
open file / new file
load file explorer from CWD
setup LSP
calculate layout
render initial frame

while running:
    poll LSP tokens
    poll git stats
    tick spinners (git tasks, search, terminal)
    if resize event:
        if too small (Terminal.isTooSmall): paint the too-small
        overlay (every resize event while small, so the message
        re-centers; input keeps working — ':q' exits; content renders
        are suppressed until the size recovers)
        else: relayoutAndRepaint (forget the frame, relayout,
        update current space windows, render — inline:
        a resize arrives with no key behind it)
    if input available:
        parse key
        poll windows (consume landed background results before the key)
        handle global key
        updateStatusBar (resync mode/cursor with focus)
        update current space windows
        render
```

**Spaces (`Spaces`):** two spaces — `editor` (explorer + tab bar + editor + git panel + branch picker + command window + commit window — it shares the command window's slot — + terminal + status bar) and `search` (search results + preview + status bar, invoked with Ctrl+F). The search windows are not part of the editor-space stack: leaving the search (Escape/Ctrl+X/Ctrl+F) returns focus to the previous top of the stack; opening a file from a result (Enter) first switches to the editor space and only then focuses the editor — focus is always set within the current space, otherwise the editor space would keep a stale focused window (for example, the explorer).

**Window stack (`windowStack`) — z-order in MRU order:**
- Invariant: the focused window is always the top of the stack. Any focusing (`focus(_:)`) raises the window to the top — including the Tab cycle, opening a panel, running a git command
- Closing (`:q`, `:bd`, `Ctrl+X`, `Escape`) — pop of the focused window; focus goes to the window right below it ("where we came from")
- The editor closes tab by tab and leaves the stack only when the last tab closes; `:wq`/`:x` are handled by the editor window itself (CommitWindow redirects them to commit; from other windows they are a no-op) and close the tab — except when the write did not happen (the changed-on-disk confirmation is awaiting an answer or was aborted, "No file name" for a `[No Name]` with text)
- An empty stack — exit the application: closing the last window (even the explorer) quits swim, without showing an empty `[No Name]`
- Tab cycles focus in stack order (bottom-up, `stackOrdered` — a deterministic order instead of an unordered dictionary)

**The command line belongs to a window:** `:` opens the command line **on the focused window** — focus is not stolen, input goes through the status bar, the command is executed against the owner window: `:q`/`:q!` close it (for the editor — tab by tab), `:w`/`:wq` save the editor's buffer, in the commit window — they commit. Allowed when the window supports `.command` (`availableModes`) and is not in insert mode — there `:` is typed literally (the terminal and passive panels have no command line at all). The owner is determined by a stateless scan of visible windows for `.command` (`commandModeWindow`) — in command mode focus cannot change (that branch swallows all keys), the "owner == focused" invariant holds. The `:e <file>` command reveals a hidden editor (`ensureEditorVisible`) and raises it to the top of the stack; opening a file from the explorer/search/a `gd` jump — likewise.

**Layout depends on window visibility and geometry** (`LayoutManager.calculate(terminalWidth:terminalHeight:space:showExplorer:showEditor:showGit:showBranches:showCommand:showTerminal:showTabBar:halfScreen:)` — the terminal size, the current space, and the `Ctrl+S` half-screen role feed it; a maximized (`Ctrl+W`) window is afterwards resized to the whole screen above the status line):
- Launching without arguments or with a directory (`swim`, `swim .`) — the editor and tab bar are not open, so the explorer takes the whole terminal (except the status line); the tree root becomes the passed directory (or CWD)
- A clean `[No Name]` tab waits off-screen — the first opened file replaces it; opening a file makes the editor visible, and the explorer shrinks to a sidebar
- `:` is always available (a command — via the status line); `Ctrl+X`/`:q`/`Escape` close the focused panel, closing the last window quits the application; `Ctrl+E` does not collapse the explorer when nothing else is visible (a toggle must not leave an empty screen)

**Global hotkeys:**
- `Ctrl+E` — file explorer
- `Ctrl+G` — git panel
- `Ctrl+B` — branch picker
- `Ctrl+F` — search
- `Ctrl+T` — built-in terminal
- `Ctrl+O` — `git pull` (from any window; output/credentials — CommandWindow)
- `Ctrl+P` — `git push` (from any window)
- `Ctrl+Y` — copy the current branch name (OSC52, from any window)
- `Ctrl+C` — exit
- `Ctrl+X` — close the focused window (tab/panel; empty stack — exit)
- `Ctrl+Z` — close all tabs except the active one (unsaved ones remain)
- `Ctrl+S` — the current panel to half the screen along its axis / back (explorer and search results — half the width; git panel, branches, command window, and terminal — half the height; preview — half the width); no effect in the editor
- `Ctrl+W` — expand the current window to full screen / restore the layout; no effect in the editor (but always restores a collapsed layout)
- `Tab` (in normal or menu mode) — cycle focus in window-stack order (the terminal types Tab literally)

**Layout (`recalculateLayout()`):**
- Single invariant: everything lives strictly above the status bar; its line is untouchable at any number of windows. The bottom stack (git → branches → command window → terminal) holds its desired heights while they fit; on overflow (already `h/2 + h/2` on any even-height terminal ≤ 50 lines — an odd 49 fits, `min(25, h/2)` floors) it compresses waterfall-style — each window gets an honest share of the remainder, a minimum of one line. The upper zone (explorer/tab bar/editor) gets the remainder and may legitimately be squeezed to 0 lines — the panels then start at the very top row, without dead padding (a squeezed window draws nothing: `Window.resize` allows 0, all bounds are guarded, the caret is clamped)
- File explorer: w/3.4 of the width (exact integer `w*5/17`), floored at 22 columns (the crossover sits at 75 columns; a narrower tree is decoration, not navigation), yielded only when the terminal cannot keep the editor's own 10-column minimum — on the left (`Ctrl+S` — half the width, same 22-column floor)
- Editor: the remaining space on the right
- Git panel / branches / command window / terminal: up to 25 lines or 1/2 of the height, at the bottom (`Ctrl+S` — exactly half the height)
- Search: results up to 1/3 of the width, preview — the rest (`Ctrl+S` — half the width for either panel)
- Status line: 1 line, at the very bottom — always visible
- Expanded window (`Ctrl+W`): the whole screen except the status line; the visibility of the other windows is preserved and restored by pressing again

**Optimized rendering (`Renderer`):**
1. The main loop calls `update()` on all visible windows of the current space (the method also polls background tasks via `poll()`)
2. For each cell of each window:
   - Compares with `prevScreenCells[row][col]` (the previous frame)
   - If changed — sends an ANSI escape to move the cursor + change attributes + write the character
   - Tracks the terminal's current attributes (`termFG`, `termBG`, `termBold`...) to avoid sending redundant escape sequences
3. `terminal.flush()` — a single write to stdout

This is diff-based rendering — only changed cells are redrawn, minimizing terminal I/O.

---

## Hotkeys

### Normal mode
| Key | Action |
|---------|----------|
| `h`/`j`/`k`/`l` | Move the cursor |
| `w` / `b` | Forward / back one word |
| `e` | Forward to the end of a word |
| `0` / `$` | Beginning / end of line |
| `Ngg` / `NG` | Go to line N; without N — beginning / end of file |
| `gt` / `gT` | Next / previous tab |
| `gd` / `gb` | Go to definition (LSP) / jump back |
| `i` / `a` / `A` / `I` | Enter Insert (before/after/end of line/beginning of line) |
| `o` / `O` | New line below/above + Insert |
| `x` | Delete character |
| `dd` | Delete line |
| `c`+motion / `cc` / `cw` | Change: delete and enter Insert; `cc` — line, `cw` — word (on a non-blank it behaves like `ce`) |
| `D` / `C` / `Y` / `S` | Aliases `d$` / `c$` / `y$` / `cc`, with a count (`Y` = `y$`, a deliberate difference from vim's `yy`) |
| `yy` | Yank line |
| `p` / `P` | Paste after/before the cursor |
| `u` / `Ctrl+R` | Undo / redo |
| `v` | Visual mode (in all visual modes: `y` — yank, `d`/`x` — delete, `s` — substitute prefill `'<,'>s/` for the selection's range, `a` — select all of the buffer; kind switching `v`/`V`/`Ctrl+V` works from visual-line and visual-block — in charwise visual `v` itself is a dead key) |
| `V` | Visual-line mode (within it: `Shift+Right`/`L` — indent, `Shift+Left`/`H` — outdent) |
| `Ctrl+V` | Visual-block mode — a rectangle in display columns, does not shrink on short/empty lines (within it: `y` — block yank, `d`/`x` — delete the block, `p` after — block paste; `v`/`V` switch back to charwise/line — switching works from visual-line and visual-block, in charwise visual `v` is a dead key) |
| `:` | Command mode (`:N` — go to line N) |
| `/` | Search forward |
| `n` / `N` | Next / previous search result (vim standard) |
| `Ctrl+j` / `Ctrl+k` | Page Down / Page Up |
| `Ctrl+h` / `Ctrl+l` | Previous / next tab (in the editor) |

### Global
| Key | Action |
|---------|----------|
| `Ctrl+E` | File explorer |
| `Ctrl+G` | Git panel |
| `Ctrl+B` | Branch picker (list in menu mode: `Enter` — `git switch`, `Ctrl+Enter` — switch+pull, `a` — create, `d`/`D` — delete locally / +remote, `i` — filter) |
| `Ctrl+F` | Project search |
| `Ctrl+T` | Built-in terminal |
| `Ctrl+O` | `git pull` from any window (output and credentials — CommandWindow) |
| `Ctrl+P` | `git push` from any window |
| `Ctrl+Y` | Copy the current branch name (OSC52) from any window |
| `Ctrl+C` | Exit |
| `Ctrl+X` | Close the focused window (tab/panel; the last window — exit) |
| `Ctrl+Z` | Close all tabs except the active one (unsaved ones remain) |
| `Ctrl+S` | Half the screen for the current panel / back |
| `Ctrl+W` | Expand the current window / restore the layout |
| `Tab` | Cycle focus in window-stack order (only from menu/normal — insert and command modes do not cycle, the terminal types it literally) |
| `:` | Command line on the focused window (except insert modes and the terminal — there it is a literal) |
| `Escape` | Normal mode; close the focused panel |

### Commands (`:`)
| Command | Action |
|---------|----------|
| `:w` | Save (in the commit window — commit) |
| `:q` | Close the command line's owner window — an editor tab or a panel (for a tab — only if there are no changes) |
| `:wq` / `:x` | Save and close the editor tab (in the commit window — commit) |
| `:q!` / `:bd!` | Close forcefully |
| `:bd` | Shares the `:q` branch — closes the command line's owner window (any window, not only an editor tab) |
| `:qa` | Quit the application — refused while any tab has unsaved changes ("No write since last change (add ! to force)") |
| `:qa!` | Quit discarding unsaved changes |
| `:e!` <path> | Open a file overriding the current tab's unsaved changes (`:e` refuses when modified) |
| `:e <path>` | Open a file (reveals a hidden editor) |
| `:terminal` / `:term` / `:sh` | Open the built-in terminal |
| `:s/pat/rep/[gic]` | Substitute; the scope is the whole buffer by default (vim-magic regex, `\0`–`\9`/`&` in the replacement; `g` — every occurrence in a line, `i` — ignore case, `c` — confirm each: `y/n/a/q/l`; the whole command is one undo step, the cursor lands on the last substitution). `'<,'>s/…` — over the selection's lines: `s` in any visual mode prefills it (a blockwise selection restricts matches to the rectangle); the marks scope lives exactly one command session. `:N[,M]s/…`, `:.,$s`, `:5,+2s`, `:+3s` — an explicit line range (a bare second offset is relative to the resolved first; backwards → "Backwards range") |
| `/<query>` | Search forward |

### Git panel (menu mode)
| Key | Action |
|---------|----------|
| `j`/`k` | Navigation; `Enter` — diff of a file/commit |
| `a` | Add: stage a file (`C` row — mark resolved; in a diff — stage the active hunk / add an untracked file) |
| `d` | Unstage (staged section/staged-diff) / discard (unstaged/untracked; in a diff — discard the active hunk) — the contextual "remove the change" |
| `D` | Discard outright — including staged content (index AND worktree back to HEAD; staged additions / the new side of a rename — `rm -f`); the one-press exception to `d`'s staged protection |
| `c` | Commit window (insert mode; `:w`/`:wq` — commit, `:q`/double Esc — cancel) |
| `C` | Commit window prefilled with the last commit's message (`git log -1 --format=%B` — subject + body) |
| `A` | Amend HEAD: the commit window with the last message (`Amend @ <hash> branch` plate), `:w` — `git commit --amend` |
| `yy` / `V`+`y` | Copy (OSC52) / visual selection |

### Branch picker (GitBranchesWindow)
| Key | Action |
|---------|----------|
| opening | `Ctrl+B` — menu mode on the list (cursor on the newest branch) |
| `j`/`k`, `Enter`, `Ctrl+Enter` in menu | Navigation; `git switch` to the selected branch via CommandWindow (output/errors visible; the window closes); `Ctrl+Enter` — the same + `git pull` right after (on the current branch — just pull) |
| `i` + typing | Live search by branch name (insert mode, input — in the window's own row; every character re-requests git); `↑`/`↓`/`Enter` — exit to menu on the first row, `Esc` — the same with a filter reset |
| `a` in menu | Branch creation: the input row becomes a name prompt (prefill — the current filter; name edits do not re-request the list). `Enter` — `git switch -c <name>` via CommandWindow, the picker closes; the name is first checked with `git check-ref-format --branch` (git is the only authority; `--branch` also strips the leading dash that `switch -c -foo` would meet with an obscure "unknown switch") — a refusal keeps the picker and the input on screen; `Esc` — back to the list, the filter untouched (the name lives in a separate buffer) |
| `m` in menu | Merge into the current branch: input of `<name> [arguments…]` — the first token is the ref, the rest passes into `git merge` as is (`side --no-ff`); the invocation is rebuilt as `git merge <args> -- <name>` — user flags stay flags, a name with a leading dash stays an operand (no option injections), validity — git's problem (visible errors). A conflicted end is not an error but a state: CommandWindow detects unmerged entries (`ls-files -u`) and holds a modal one-key choice — `k` keep for manual resolution (then commit from the git panel), `o`/`t` abort and merge again with `-X ours/theirs` (the user's arguments — `--no-ff` etc. — are preserved in the retry), `Esc` — `git merge --abort`; a new command in the window dismisses the choice |
| `d` in menu | Delete the selected branch locally: `git branch -d` via CommandWindow (git itself refuses on the current branch — a local guard with a message — and on unmerged work; the picker stays open, `gitCommandFinished` refreshes the list) |
| `D` in menu | Locally + remote: first `git branch -d`, then `git push <remote> --delete <name>` (the follow-up only after the local half succeeds). The remote — the branch's upstream (`name@{upstream}`), or the repository's only remote when there is none; several remotes without an upstream — refuse with a message, the local half is not silently deleted |
| `Esc` in menu | Close the window |

---

## Performance optimizations

1. **Pre-allocation in `rebuildLineIndex()`** — `reserveCapacity` based on file size prevents ~22 reallocations for files with millions of lines

2. **`withUnsafeBufferPointer`** — direct buffer memory access when scanning for line breaks

3. **Line cache** — `getLine()` caches the last decoded line, avoiding redundant UTF-8 decoding

4. **Diff-based rendering** — only changed cells are redrawn via comparison with `prevScreenCells`

5. **Attribute tracking** — an ANSI escape to change color/style is sent only if the attribute actually changed

6. **Incremental LSP sync** — instead of the full text on every keystroke, only range-based changes are sent (O(line length) for position conversion instead of O(file size)); `didOpen` for files >5MB is still skipped

7. **Skipping highlighting for large files** — the built-in tokenizer is disabled for files >50K lines

8. **Fast JSON rendering** — for `.json` files, highlighting is a character-by-character pass over each visible line at render time, without keyword tables: adjacent same-type characters are merged into `[SemanticToken]` runs right away
