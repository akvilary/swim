#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
@preconcurrency
import Foundation

class Application: WindowDelegate {
    private let terminal = Terminal.shared
    private let spaces = Spaces()
    private var running = true
    private var lspClients: [String: LSPClient] = [:]
    private var lspVersion: Int = 0
    private var pendingTokenRefresh: (path: String, earliest: TimeInterval)?
    private lazy var renderer = Renderer(terminal: terminal)

    /// Git info for the status bar: branch + added/deleted lines of the
    /// working tree (git diff HEAD --numstat) and of the open file —
    /// fetched in the background on file save / open / tab switch.
    private struct GitStats {
        var branch: String?
        var added = 0
        var deleted = 0
        var fileAdded = 0
        var fileDeleted = 0
    }
    private let gitStatsTask = BackgroundTask<GitStats>()
    /// Fetches are serialized through a single state: a request arriving
    /// while a fetch is running is coalesced into one refetch afterwards
    /// (BackgroundTask has a single result slot — overlapping threads would
    /// clobber each other's results before the main loop consumes them).
    private enum GitStatsState {
        case idle
        case running
        case runningQueued
    }
    private var gitStatsState: GitStatsState = .idle

    private var halfScreenWindow: Window?
    private var maximized: Window?
    private var maximizeHidden: [Window] = []

    /// Z-order stack of open windows; the last element is the top (most
    /// recently opened). Closing a window pops it and reveals the window
    /// beneath; when the stack empties the app quits.
    private var windowStack: [Window] = []

    private let editor = EditorWindow()
    private let statusBar = StatusBarWindow()
    private let tabBar = TabBarWindow()
    private let fileExplorer = FileExplorerWindow()
    private let gitPanel = GitPanelWindow()
    private let commitWindow = CommitWindow()
    private let searchResults = SearchResultsWindow()
    private let preview = PreviewWindow()
    private let command = CommandWindow()
    private let terminalWindow = TerminalWindow()

    init(filePath: String? = nil) {
        let editorSpace = Space(id: "editor", delegate: self)
        editorSpace.addWindow("fileExplorer", fileExplorer)
        editorSpace.addWindow("tabBar", tabBar)
        editorSpace.addWindow("editor", editor)
        editorSpace.addWindow("gitPanel", gitPanel)
        editorSpace.addWindow("command", command)
        editorSpace.addWindow("commit", commitWindow)
        editorSpace.addWindow("terminal", terminalWindow)
        editorSpace.addWindow("statusBar", statusBar)

        let searchSpace = Space(id: "search", delegate: self)
        searchSpace.addWindow("searchResults", searchResults)
        searchSpace.addWindow("preview", preview)
        searchSpace.addWindow("statusBar", statusBar)

        spaces.addSpace(editorSpace)
        spaces.addSpace(searchSpace)
        spaces.switchTo("editor")

        tabBar.tabsSource = editor

        var startDir = FileManager.default.currentDirectoryPath
        if let path = filePath, isDirectory(path) {
            // The CLI argument may be relative (`swim .`); the LSP root and
            // explorer paths must be absolute.
            startDir = BufferManager.normalize(path)
        }

        var fileToOpen: String?
        if let path = filePath, !isDirectory(path) {
            fileToOpen = path
            editor.openFile(path)
        } else {
            // No file argument (or a directory like `swim .`): keep the
            // editor closed — the explorer fills the terminal until the
            // user opens a concrete file. A pristine [No Name] tab waits
            // behind it and is replaced by the first opened file.
            editor.newFile()
        }
        updateStatusBar()

        fileExplorer.visible = true
        editor.visible = fileToOpen != nil
        tabBar.visible = fileToOpen != nil
        statusBar.visible = true
        fileExplorer.loadDirectory(startDir)
        gitPanel.workingDirectory = startDir

        // Initial window stack: explorer at the bottom, editor on top of it
        // when a file was opened from the command line.
        windowStack = [fileExplorer]
        if fileToOpen != nil { windowStack.append(editor) }

        setupLSP(rootPath: startDir)
        fetchGitStats()

        spaces.current.focused = fileToOpen != nil ? editor : fileExplorer
        spaces.current.updateFocusStates()
    }

    func run() {
        terminal.setup()

        if terminal.width < 10 || terminal.height < 5 {
            terminal.restore()
            let msg = "Error: Swim requires a terminal with at least 10x5 size.\n"
            let bytes = [UInt8](msg.utf8)
            bytes.withUnsafeBufferPointer { ptr in
                _ = write(STDERR_FILENO, ptr.baseAddress, bytes.count)
            }
            return
        }

        recalculateLayout()
        spaces.current.update()
        render()

        while running {
            pollLSP()
            pollGitStats()
            tickSpinners()
            if terminal.hasResizeEvent {
                terminal.consumeResizeEvent()
                renderer.needsFullRedraw = true
                recalculateLayout()
                spaces.markAllDirty()
                spaces.current.update()
                render()
            }
            if terminal.bytesAvailable() {
                if let key = Key.parse(from: terminal) {
                    // Consume completed background results before the key
                    // is handled: handlers must act on the freshest state,
                    // otherwise key/result interleaving is nondeterministic
                    // (a navigation move could land on a stale list).
                    spaces.current.pollWindows()
                    handleGlobalKey(key)
                    // The status bar mirrors the focused window (mode,
                    // cursor) — resync after every key so focus moves from
                    // toggles, Tab cycling and space switches are reflected
                    // even when their handlers don't update it themselves.
                    updateStatusBar()
                }
                spaces.current.update()
                render()
            }
        }

        for (_, client) in lspClients { client.stop() }
        terminal.restore()
    }

    private func fetchGitStats() {
        switch gitStatsState {
        case .idle:
            gitStatsState = .running
            startGitStatsFetch()
        case .running:
            gitStatsState = .runningQueued
        case .runningQueued:
            break
        }
    }

    private func startGitStatsFetch() {
        let dir = gitPanel.workingDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : gitPanel.workingDirectory
        let filePath = editor.filePath
        gitStatsTask.start {
            let branchResult = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], workDir: dir)
            guard branchResult.exitCode == 0 else {
                return GitStats(branch: nil)
            }
            let name = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            var stats = GitStats(branch: name.isEmpty ? nil : name)

            let rootResult = Shell.git(["rev-parse", "--show-toplevel"], workDir: dir)
            let root = rootResult.exitCode == 0
                ? rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : dir

            let numstat = Shell.git(["diff", "HEAD", "--numstat"], workDir: dir)
            for line in numstat.stdout.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 3 else { continue }
                let a = Int(cols[0]) ?? 0
                let d = Int(cols[1]) ?? 0
                stats.added += a
                stats.deleted += d
                if let filePath, BufferManager.normalize(root + "/" + cols[2]) == filePath {
                    stats.fileAdded = a
                    stats.fileDeleted = d
                }
            }

            // Untracked files never appear in `git diff HEAD` — for the open
            // file show its whole content as additions.
            if let filePath, stats.fileAdded == 0, stats.fileDeleted == 0 {
                let status = Shell.git(["status", "--porcelain", "--", filePath], workDir: dir)
                if status.stdout.hasPrefix("??"),
                   let text = try? String(contentsOfFile: filePath, encoding: .utf8),
                   !text.isEmpty {
                    stats.fileAdded = text.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            }
            return stats
        }
    }

    private func pollGitStats() {
        guard let stats = gitStatsTask.consume() else { return }
        let refetchQueued = gitStatsState == .runningQueued
        gitStatsState = .idle

        if statusBar.branch != stats.branch
            || statusBar.branchAdded != stats.added
            || statusBar.branchDeleted != stats.deleted
            || statusBar.fileAdded != stats.fileAdded
            || statusBar.fileDeleted != stats.fileDeleted {
            statusBar.branch = stats.branch
            statusBar.branchAdded = stats.added
            statusBar.branchDeleted = stats.deleted
            statusBar.fileAdded = stats.fileAdded
            statusBar.fileDeleted = stats.fileDeleted
            statusBar.dirty = true
            spaces.current.update()
            render()
        }

        if refetchQueued {
            fetchGitStats()
        }
    }

    private func pollLSP() {
        // Debounced semantic tokens refresh after edits
        if let refresh = pendingTokenRefresh, Date().timeIntervalSince1970 >= refresh.earliest {
            pendingTokenRefresh = nil
            if let key = lspClientKey(for: refresh.path),
               let client = lspClients[key], client.isReady {
                client.requestSemanticTokens(uri: "file://\(refresh.path)")
            }
        }

        for (_, client) in lspClients {
            if let pending = client.takePendingTokens() {
                let path = pathFromUri(pending.uri)
                guard let target = editor.findBuffer(forNormalizedPath: path) else { continue }
                if editor.applySemanticTokens(pending.tokens, to: target) {
                    spaces.current.update()
                    render()
                }
            }
            if let result = client.takePendingDefinition() {
                switch result {
                case .notFound:
                    editor.lastError = "No definition found"
                    updateStatusBar()
                    spaces.current.update()
                    render()
                case .found(let definition):
                    performDefinitionJump(definition)
                }
            }
        }
    }

    private func performDefinitionJump(_ definition: LSPDefinition) {
        let path = pathFromUri(definition.uri)
        guard !path.isEmpty else { return }
        pushJumpHistory()
        jump(to: path, line: definition.line, colUtf16: definition.charUtf16)
    }

    /// Jump locations (`gb` targets) of the last `gd` jumps, oldest first.
    private var jumpStack: [(path: String, line: Int, colUtf16: Int)] = []
    private let jumpStackLimit = 50

    private func pushJumpHistory() {
        guard let path = editor.filePath, let buf = editor.buffer else { return }
        let col = buf.utf16ColForCharIndex(line: editor.cursorLine, charIndex: editor.cursorCol)
        jumpStack.append((path: path, line: editor.cursorLine, colUtf16: col))
        if jumpStack.count > jumpStackLimit {
            jumpStack.removeFirst(jumpStack.count - jumpStackLimit)
        }
    }

    func requestGoBack() {
        guard let target = jumpStack.popLast() else {
            editor.lastError = "No previous position"
            return
        }
        jump(to: target.path, line: target.line, colUtf16: target.colUtf16)
    }

    /// Tab-aware jump: opens or switches to the target file's tab (no reload
    /// of unsaved buffers) and positions the cursor.
    private func jump(to path: String, line: Int, colUtf16: Int) {
        if spaces.current.id != "editor" {
            switchToSpace("editor")
        }
        if path != editor.filePath {
            openFileInEditor(path)
        }
        editor.goToPosition(line: line, colUtf16: colUtf16)
        updateStatusBar()
        spaces.current.update()
        render()
    }

    func requestGoToDefinition(line: Int, charUtf16: Int) {
        guard let path = editor.filePath else {
            editor.lastError = "Unnamed buffer — save the file first"
            return
        }
        guard let key = lspClientKey(for: path), let client = lspClients[key] else {
            editor.lastError = "No LSP server for this file type"
            return
        }
        guard client.isReady else {
            editor.lastError = "LSP server is not ready"
            return
        }
        client.requestDefinition(uri: "file://\(path)", line: line, character: charUtf16)
    }

    private func pathFromUri(_ uri: String) -> String {
        guard uri.hasPrefix("file://") else { return uri }
        if let url = URL(string: uri), url.scheme == "file" {
            return BufferManager.normalize(url.path)
        }
        return BufferManager.normalize(String(uri.dropFirst("file://".count)))
    }

    private var lastSpinnerTick: TimeInterval = 0

    private func tickSpinners() {
        let now = Date().timeIntervalSince1970
        guard now - lastSpinnerTick >= 0.1 else { return }
        var anyDirty = false
        if command.visible && command.isRunning {
            command.spinnerFrame &+= 1
            command.dirty = true
            anyDirty = true
        }
        if searchResults.visible && searchResults.isSearching {
            searchResults.dirty = true
            anyDirty = true
        }
        if gitPanel.visible && gitPanel.isRefreshing {
            gitPanel.dirty = true
            anyDirty = true
        }
        if gitPanel.visible && gitPanel.isDiffLoading {
            gitPanel.diffSpinnerFrame &+= 1
            gitPanel.dirty = true
            anyDirty = true
        }
        if terminalWindow.visible && terminalWindow.isRunning {
            terminalWindow.spinnerFrame &+= 1
            terminalWindow.dirty = true
            anyDirty = true
        }
        if anyDirty {
            lastSpinnerTick = now
            spaces.current.update()
            render()
        }
    }

    private func setupLSP(rootPath: String) {
        let swiftPaths = [
            "/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/home/linuxbrew/.linuxbrew/bin/sourcekit-lsp",
            "\(NSHomeDirectory())/.swiftenv/shims/sourcekit-lsp",
        ]

        if let path = findExecutable(paths: swiftPaths, command: "sourcekit-lsp") {
            let client = LSPClient()
            client.start(executable: path, rootUri: "file://\(rootPath)")
            lspClients["swift"] = client
        }

        let csharpPaths = [
            "/usr/bin/omnisharp",
            "/usr/local/bin/omnisharp",
            "\(NSHomeDirectory())/.dotnet/tools/omnisharp",
        ]

        if let path = findExecutable(paths: csharpPaths, command: "omnisharp") {
            let client = LSPClient()
            client.start(executable: path, arguments: ["-lsp"], rootUri: "file://\(rootPath)")
            lspClients["csharp"] = client
        }

        let goPaths = [
            "/usr/bin/gopls",
            "/usr/local/bin/gopls",
            "/home/linuxbrew/.linuxbrew/bin/gopls",
            "/opt/homebrew/bin/gopls",
            "\(NSHomeDirectory())/go/bin/gopls",
        ]

        if let path = findExecutable(paths: goPaths, command: "gopls") {
            let client = LSPClient()
            client.start(executable: path, rootUri: "file://\(rootPath)")
            lspClients["go"] = client
        }

        let rustPaths = [
            "/usr/bin/rust-analyzer",
            "/usr/local/bin/rust-analyzer",
            "/home/linuxbrew/.linuxbrew/bin/rust-analyzer",
            "/opt/homebrew/bin/rust-analyzer",
            "\(NSHomeDirectory())/.cargo/bin/rust-analyzer",
        ]

        if let path = findExecutable(paths: rustPaths, command: "rust-analyzer") {
            let client = LSPClient()
            client.start(executable: path, rootUri: "file://\(rootPath)")
            lspClients["rust"] = client
        }

        let bashPaths = [
            "/usr/bin/bash-language-server",
            "/usr/local/bin/bash-language-server",
            "/home/linuxbrew/.linuxbrew/bin/bash-language-server",
            "/opt/homebrew/bin/bash-language-server",
            "\(NSHomeDirectory())/.npm-global/bin/bash-language-server",
            "\(NSHomeDirectory())/.local/bin/bash-language-server",
        ]

        if let path = findExecutable(paths: bashPaths, command: "bash-language-server") {
            let client = LSPClient()
            client.start(executable: path, arguments: ["start"], rootUri: "file://\(rootPath)")
            lspClients["bash"] = client
        }

        // Python: basedpyright only — it is the pyright fork that implements
        // semantic tokens (pyright lacks them entirely). pip/uv install.
        // [tool.basedpyright]/[tool.pyright] extraPaths and pyrightconfig.json
        // are read by the server itself; as a fallback we forward pytest's
        // [tool.pytest.ini_options].pythonpath via initializationOptions —
        // but never when an explicit server config exists (it would override).
        let basedPyrightPaths = [
            "/usr/local/bin/basedpyright-langserver",
            "/usr/bin/basedpyright-langserver",
            "/home/linuxbrew/.linuxbrew/bin/basedpyright-langserver",
            "/opt/homebrew/bin/basedpyright-langserver",
            "\(NSHomeDirectory())/.local/bin/basedpyright-langserver",
        ]

        if let path = findExecutable(paths: basedPyrightPaths, command: "basedpyright-langserver") {
            let client = LSPClient()
            client.start(
                executable: path,
                arguments: ["--stdio"],
                rootUri: "file://\(rootPath)",
                initializationOptions: pythonInitializationOptions(rootPath: rootPath)
            )
            lspClients["python"] = client
        }

        if let filePath = editor.filePath {
            notifyLSPFileOpen(filePath)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Builds basedpyright initializationOptions:
    /// - diagnosticMode openFilesOnly — basedpyright (unlike pyright) analyzes
    ///   the whole workspace by default, burning a CPU core for the entire
    ///   session on large monorepos; we don't display diagnostics yet and
    ///   definitions work with open-files-only analysis.
    /// - extraPaths from pytest's `[tool.pytest.ini_options].pythonpath`.
    /// Returns nil when the server has its own config ([tool.basedpyright],
    /// [tool.pyright] or pyrightconfig.json) — that config must win.
    private func pythonInitializationOptions(rootPath: String) -> [String: Any]? {
        let pyprojectPath = rootPath + "/pyproject.toml"
        guard let text = try? String(contentsOfFile: pyprojectPath, encoding: .utf8) else {
            return ["settings": [["uri": "file://\(rootPath)",
                                  "settings": ["diagnosticMode": "openFilesOnly"]]]]
        }
        guard !Self.tomlHasSection(text, "tool.basedpyright"),
              !Self.tomlHasSection(text, "tool.pyright"),
              !FileManager.default.fileExists(atPath: rootPath + "/pyrightconfig.json") else { return nil }

        var settings: [String: Any] = ["diagnosticMode": "openFilesOnly"]
        let extra = Self.tomlStringArray(in: text, section: "tool.pytest.ini_options", key: "pythonpath")
        if !extra.isEmpty {
            let absolute = extra.map { $0.hasPrefix("/") ? $0 : rootPath + "/" + $0 }
            settings["extraPaths"] = absolute
        }
        return ["settings": [["uri": "file://\(rootPath)", "settings": settings]]]
    }

    /// True when the TOML text contains the `[section]` header.
    private static func tomlHasSection(_ text: String, _ section: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { return false }
            return t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == section
        }
    }

    /// Extracts a string-array value of `key` from a `[section]` of TOML text
    /// (pyproject-lite: quoted strings, # comments, multi-line arrays).
    private static func tomlStringArray(in text: String, section: String, key: String) -> [String] {
        func parseArray(_ s: String) -> [String] {
            guard let open = s.firstIndex(of: "["), let close = s.lastIndex(of: "]"), open < close else { return [] }
            return s[s.index(after: open)..<close]
                .split(separator: ",")
                .compactMap { item -> String? in
                    var t = item.trimmingCharacters(in: .whitespaces)
                    if let hash = t.firstIndex(of: "#") {
                        t = String(t[..<hash]).trimmingCharacters(in: .whitespaces)
                    }
                    guard t.count >= 2 else { return nil }
                    let first = t.first, last = t.last
                    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        return String(t.dropFirst().dropLast())
                    }
                    return nil
                }
        }

        var inSection = false
        var collecting = false
        var buffer = ""
        var result = [String]()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSection = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == section
                continue
            }
            guard inSection else { continue }
            if collecting {
                buffer += " " + line
                if line.contains("]") {
                    collecting = false
                    result.append(contentsOf: parseArray(buffer))
                    buffer = ""
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = String(line[line.index(after: eq)...])
            if value.contains("]") {
                result.append(contentsOf: parseArray(value))
            } else {
                buffer = value
                collecting = true
            }
        }
        return result
    }

    private func findExecutable(paths: [String], command: String) -> String? {
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let which = Shell.run(executable: "/usr/bin/which", args: [command]).stdout
        let result = which.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func lspClientKey(for filePath: String) -> String? {
        let ext = (filePath as NSString).pathExtension
        switch ext {
        case "swift": return "swift"
        case "cs", "csx": return "csharp"
        case "go": return "go"
        case "rs": return "rust"
        case "sh", "bash": return "bash"
        case "py", "pyw", "pyi": return "python"
        default: return nil
        }
    }

    private func notifyLSPFileOpen(_ path: String) {
        guard let key = lspClientKey(for: path),
              let client = lspClients[key] else { return }
        guard let buf = editor.buffer, buf.totalLength < 5_000_000 else { return }
        let normalized = BufferManager.normalize(path)
        let uri = "file://\(normalized)"
        let langId = SyntaxTokenizer.languageId(for: (normalized as NSString).pathExtension)
        client.openDocument(uri: uri, languageId: langId, text: buf.getAllText())
    }

    private func handleGlobalKey(_ key: Key) {
        if editor.lastError != nil { editor.lastError = nil }
        // The window that owns the command line consumes every key while
        // it is being typed (focus cannot change mid-command).
        if let owner = commandModeWindow {
            var isEnter = false
            if case .enter = key { isEnter = true }
            let pathBefore = editor.filePath
            _ = owner.handleCommandModeKey(key)
            // A command like `:e` may have opened a file while the editor
            // was hidden or another space was active — reveal it now.
            if isEnter, owner === editor, case .normal = editor.mode,
               editor.filePath != nil, editor.filePath != pathBefore {
                if !editor.visible { ensureEditorVisible() }
                if spaces.current.id != "editor" { switchToSpace("editor") }
                focus(editor)
            }
            updateStatusBar()
            if owner === editor { notifyLSPChange() }
            return
        }

        switch key {
        case .ctrl("e"):
            toggleFileExplorer()
            return
        case .ctrl("g"):
            toggleGitPanel()
            return
        case .ctrl("f"):
            toggleSearch()
            return
        case .ctrl("t"):
            toggleTerminal()
            return
        case .ctrl("c"):
            running = false
            return
        case .ctrl("x"):
            if let focused = spaces.current.focused, focused !== editor,
               focused !== statusBar, focused !== tabBar {
                closeWindow(focused)
            } else if editor.visible {
                closeCurrentTab(force: false)
            }
            return
        case .ctrl("z"):
            if editor.visible {
                closeOtherTabs()
            }
            return
        case .ctrl("s"):
            if spaces.current.focused !== editor {
                toggleHalfScreen()
                return
            }
        case .ctrl("w"):
            if maximized != nil || spaces.current.focused !== editor {
                toggleMaximize()
                return
            }
        default:
            break
        }

        // Tab cycles focus, but only from modes that don't take text:
        // insert (editor, search query, commit message) and command
        // modes consume it, and the terminal types it literally.
        if case .tab = key, spaces.current.focused !== terminalWindow,
           let focused = spaces.current.focused,
           focused.mode == .menu || focused.mode == .normal {
            cycleFocus()
            return
        }

        if case .char(":") = key, canOpenCommandLine() {
            openCommandLine()
            return
        }

        let focused = spaces.current.focused ?? editor
        if focused.handleKey(key) {
            if focused === editor {
                updateStatusBar()
                notifyLSPChange()
            }
        } else if case .escape = key, focused !== editor {
            closeWindow(focused)
        }
    }

    /// `:` opens the command line on the focused window — allowed when
    /// that window supports command mode and is not taking text (insert
    /// mode types `:` literally). Windows without command mode (the
    /// terminal, passive panels) never open it.
    private func canOpenCommandLine() -> Bool {
        guard let focused = spaces.current.focused,
              focused.availableModes.contains(.command) else { return false }
        return focused.mode != .insert
    }

    /// Enters command mode on the focused window: the command line is
    /// owned by that window — `:q` closes it, an editor's `:w` saves it.
    /// The focused window keeps focus and its place on the stack; the
    /// command is typed through the status bar.
    private func openCommandLine() {
        spaces.current.focused?.enterCommandMode()
        updateStatusBar()
    }

    /// Closes a window (`:q`, Ctrl+X, Esc): pops it from the window stack
    /// and reveals the window beneath. The editor closes tab by tab and only
    /// leaves the stack when its last tab is closed. Popping the last window
    /// quits the app.
    private func closeWindow(_ window: Window, force: Bool = false) {
        guard window !== statusBar, window !== tabBar else { return }
        if maximized != nil { restoreMaximized() }

        var target = window
        if spaces.current.id != "editor" {
            // The search space closes as one unit — back to the editor-space
            // window stack, where the search window sits on top.
            switchToSpace("editor")
            target = searchResults
        }

        if target === editor {
            if editor.visible { closeCurrentTab(force: force) }
            return
        }
        popWindow(target)
    }

    /// `:q` / `:bd` close the focused window — always the stack top.
    private func closeFocusedWindow(force: Bool) {
        guard let focused = spaces.current.focused,
              focused !== statusBar, focused !== tabBar else { return }
        closeWindow(focused, force: force)
    }

    /// Pops a window off the stack, hides it, and hands focus to the window
    /// beneath (the new stack top). An empty stack exits the app.
    private func popWindow(_ window: Window) {
        removeFromStack(window)
        window.visible = false
        if window === editor { tabBar.visible = false }
        if halfScreenWindow === window { halfScreenWindow = nil }
        guard focusStackTop() else {
            running = false
            return
        }
        spaces.current.updateFocusStates()
        recalculateLayout()
        spaces.markAllDirty()
        updateStatusBar()
    }

    /// Raises a window to the top of the stack (opening or re-opening it).
    private func pushWindow(_ window: Window) {
        removeFromStack(window)
        windowStack.append(window)
    }

    private func removeFromStack(_ window: Window) {
        windowStack.removeAll { $0 === window }
    }

    /// Focuses the stack top. Returns false when the stack is empty.
    @discardableResult
    private func focusStackTop() -> Bool {
        guard let top = windowStack.last else { return false }
        spaces.current.focused = top
        return true
    }

    /// Focusing a window raises it to the top of the window stack, so the
    /// focused window is always the stack top and closing pops exactly it.
    private func focus(_ window: Window) {
        pushWindow(window)
        spaces.current.focused = window
        spaces.current.updateFocusStates()
    }

    private func toggleFileExplorer() {
        if maximized != nil {
            restoreMaximized()
            recalculateLayout()
            spaces.markAllDirty()
        }
        // Without an editor there is nothing else to show — keep the explorer.
        guard editor.visible || !fileExplorer.visible else { return }
        fileExplorer.visible = !fileExplorer.visible
        if fileExplorer.visible {
            focus(fileExplorer)
        } else {
            popWindow(fileExplorer)
            return
        }
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func toggleGitPanel() {
        if maximized != nil { restoreMaximized() }
        gitPanel.visible = !gitPanel.visible
        if gitPanel.visible {
            // A diff left open when the panel was closed (`:q`, Ctrl+X)
            // would show stale content on reopen — return to the list.
            gitPanel.closeDiffView()
            gitPanel.refresh()
            focus(gitPanel)
        } else {
            popWindow(gitPanel)
            return
        }
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func toggleSearch() {
        if maximized != nil { restoreMaximized() }
        if spaces.current.id == "search" {
            switchToSpace("editor")
            focusStackTop()
            spaces.current.updateFocusStates()
        } else {
            searchResults.visible = true
            preview.visible = true
            switchToSpace("search")
            let cwd = gitPanel.workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : gitPanel.workingDirectory
            searchResults.prepareInput(workingDirectory: cwd)
            let searchQuery = editor.searchQuery
            if !searchQuery.isEmpty {
                searchResults.search(query: searchQuery, in: cwd)
            }
            focus(searchResults)
        }
    }

    private func toggleTerminal() {
        if terminalWindow.visible {
            popWindow(terminalWindow)
            return
        }
        openTerminal()
    }

    private func openTerminal() {
        if maximized != nil { restoreMaximized() }
        if spaces.current.id != "editor" { switchToSpace("editor") }
        let cwd = gitPanel.workingDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : gitPanel.workingDirectory
        terminalWindow.prepare(workingDirectory: cwd)
        terminalWindow.visible = true
        focus(terminalWindow)
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func switchToSpace(_ spaceId: String) {
        if spaceId == "editor" {
            // Search windows only exist inside the search space — they never
            // belong to the editor-space window stack.
            removeFromStack(searchResults)
            removeFromStack(preview)
        }
        spaces.switchTo(spaceId)
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func cycleFocus() {
        let focusable = stackOrdered(spaces.current.focusable())
        guard focusable.count > 1 else { return }
        guard let currentIdx = focusable.firstIndex(where: { $0 === spaces.current.focused }) else { return }
        focus(focusable[(currentIdx + 1) % focusable.count])
        spaces.markAllDirty()
    }

    /// Deterministic focus order: windows bottom-to-top of the stack, then
    /// anything not tracked by the stack (none in practice).
    private func stackOrdered(_ windows: [Window]) -> [Window] {
        var rank: [ObjectIdentifier: Int] = [:]
        for (idx, window) in windowStack.enumerated() {
            rank[ObjectIdentifier(window)] = idx
        }
        return windows.sorted {
            let a = rank[ObjectIdentifier($0)] ?? .max
            let b = rank[ObjectIdentifier($1)] ?? .max
            return a < b
        }
    }

    private func toggleHalfScreen() {
        if maximized != nil { restoreMaximized() }
        guard let target = spaces.current.focused,
              target !== statusBar, target !== tabBar else { return }
        halfScreenWindow = halfScreenWindow === target ? nil : target
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func halfScreenRole() -> HalfScreenWindow {
        guard let window = halfScreenWindow else { return .none }
        if window === fileExplorer { return .explorer }
        if window === gitPanel { return .git }
        if window === command || window === commitWindow { return .command }
        if window === terminalWindow { return .terminal }
        if window === searchResults { return .searchResults }
        if window === preview { return .preview }
        return .none
    }

    private func toggleMaximize() {
        if maximized != nil {
            restoreMaximized()
            recalculateLayout()
            spaces.markAllDirty()
            return
        }
        guard let target = spaces.current.focused, target !== statusBar else { return }
        maximized = target
        maximizeHidden = spaces.current.visibleWindows.filter { $0 !== target && $0 !== statusBar }
        for window in maximizeHidden {
            window.visible = false
        }
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func restoreMaximized() {
        for window in maximizeHidden {
            window.visible = true
        }
        maximizeHidden = []
        maximized = nil
    }

    private func recalculateLayout() {
        let layout = LayoutManager.calculate(
            terminalWidth: terminal.width,
            terminalHeight: terminal.height,
            space: spaces.current.id,
            showExplorer: fileExplorer.visible,
            showEditor: editor.visible,
            showGit: gitPanel.visible,
            showCommand: command.visible || commitWindow.visible,
            showTerminal: terminalWindow.visible,
            showTabBar: editor.visible && tabBar.visible,
            halfScreen: halfScreenRole()
        )

        fileExplorer.resize(x: layout.explorer.x, y: layout.explorer.y, width: layout.explorer.width, height: layout.explorer.height)
        tabBar.resize(x: layout.tabbar.x, y: layout.tabbar.y, width: layout.tabbar.width, height: layout.tabbar.height)
        editor.resize(x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: layout.editor.height)
        gitPanel.resize(x: layout.git.x, y: layout.git.y, width: layout.git.width, height: layout.git.height)
        searchResults.resize(x: layout.searchResults.x, y: layout.searchResults.y, width: layout.searchResults.width, height: layout.searchResults.height)
        preview.resize(x: layout.preview.x, y: layout.preview.y, width: layout.preview.width, height: layout.preview.height)
        command.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        commitWindow.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        terminalWindow.resize(x: layout.terminal.x, y: layout.terminal.y, width: layout.terminal.width, height: layout.terminal.height)
        statusBar.resize(x: layout.status.x, y: layout.status.y, width: layout.status.width, height: layout.status.height)

        if let maximized {
            maximized.resize(x: 0, y: 0, width: terminal.width, height: max(1, terminal.height - 1))
        }
    }

    /// Shows the editor (and tab bar) when a file gets opened or the user
    /// explicitly requests another panel while the editor is still closed.
    private func ensureEditorVisible() {
        guard !editor.visible else { return }
        editor.visible = true
        tabBar.visible = true
        pushWindow(editor)
        recalculateLayout()
    }

    /// The window currently owning the command line. Only the focused
    /// window can enter command mode and focus cannot change while the
    /// command is being typed, so at most one visible window is in
    /// command mode.
    private var commandModeWindow: Window? {
        spaces.current.visibleWindows.first { $0.mode == .command }
    }

    private func render() {
        // Each visible window may own a typing surface (editor insert
        // caret, status-bar command caret) and provides the terminal
        // cursor for it; by focus rules at most one is active.
        let cursorInfo = spaces.current.visibleWindows.compactMap { $0.cursorRenderInfo() }.last
        if editor.visible {
            renderer.render(
                windows: spaces.current.visibleWindows,
                cursorInfo: cursorInfo,
                editorScrollY: editor.scrollY,
                editorRect: (editor.x, editor.y, editor.width, editor.height)
            )
        } else {
            renderer.render(windows: spaces.current.visibleWindows, cursorInfo: cursorInfo)
        }
    }

    private func updateStatusBar() {
        // The mode label and command text come from the window that owns
        // the command line, else from the focused window; cursor stats
        // come from the focused editor when one has focus (main or
        // commit), else from the main editor.
        let focused = spaces.current.focused
        let modeSource = commandModeWindow ?? focused ?? editor
        let statsSource = (focused is EditorWindow) ? (focused as! EditorWindow) : editor
        statusBar.commandSource = modeSource
        statusBar.cursorLine = statsSource.cursorLine
        statusBar.cursorCol = statsSource.cursorCol
        statusBar.totalLines = statsSource.buffer?.lineCount ?? 0
        if let path = statsSource.filePath {
            let ext = (path as NSString).pathExtension
            statusBar.fileType = ext.isEmpty ? "" : "[\(ext)]"
        } else {
            statusBar.fileType = ""
        }
        statusBar.errorMessage = editor.lastError
        tabBar.dirty = true
        statusBar.dirty = true
    }

    func handleEditorCommand(_ cmd: String) {
        switch cmd {
        case "quit", "q", "bd":
            closeFocusedWindow(force: false)
        case "forcequit", "bd!", "q!":
            closeFocusedWindow(force: true)
        case "wquit":
            closeCurrentTab(force: false)
        case "terminal", "term", "sh":
            openTerminal()
        case "qa":
            // vim semantics: refuse to quit all while any tab has unsaved
            // changes; `qa!` discards them.
            if editor.tabs.anyModified {
                editor.lastError = "No write since last change (add ! to force)"
                updateStatusBar()
            } else {
                running = false
            }
        case "qa!":
            running = false
        default:
            break
        }
    }

    private func closeCurrentTab(force: Bool) {
        let wasLast = editor.tabCount == 1
        guard let closed = editor.closeCurrentTab(force: force) else {
            editor.lastError = "No write since last change (add ! to force)"
            updateStatusBar()
            return
        }
        notifyLSPClose(closed.filePath)
        if wasLast {
            // The last tab closed — the editor window pops off the stack and
            // the window beneath is revealed (or the app quits).
            popWindow(editor)
            return
        }
        updateStatusBar()
    }

    private func closeOtherTabs() {
        let (closed, keptModified) = editor.closeOtherTabs()
        for buffer in closed {
            notifyLSPClose(buffer.filePath)
        }
        if closed.isEmpty && keptModified == 0 {
            editor.lastError = "No other tabs"
        } else if keptModified > 0 {
            editor.lastError = "Kept \(keptModified) tab(s) with unsaved changes"
        }
        updateStatusBar()
    }

    func bufferClosed(_ buffer: EditorBuffer) {
        notifyLSPClose(buffer.filePath)
        tabBar.dirty = true
    }

    private func notifyLSPClose(_ filePath: String?) {
        guard let path = filePath,
              let key = lspClientKey(for: path),
              let client = lspClients[key] else { return }
        client.closeDocument(uri: "file://\(path)")
    }

    func openFile(_ path: String) {
        openFileInEditor(path)
    }

    func openFileAtLine(_ path: String, line: Int) {
        // Switch first: openFileInEditor focuses the editor, and focus must
        // land in the editor space — focusing while the search space is
        // current would leave the editor space's stale focus (explorer).
        if spaces.current.id != "editor" {
            switchToSpace("editor")
        }
        openFileInEditor(path)
        // Show where we are: the explorer expands to and highlights the file.
        fileExplorer.reveal(path: BufferManager.normalize(path))
        // goToPosition clamps the line to the buffer (a search index may be
        // stale after edits) and resets the column — a cursorCol carried
        // over from the previous buffer would shift scrollX.
        editor.goToPosition(line: line - 1, colUtf16: 0)
        updateStatusBar()
    }

    private func openFileInEditor(_ path: String) {
        ensureEditorVisible()
        let isNew = editor.openFile(path)
        editor.dirty = true
        updateStatusBar()
        if isNew { notifyLSPFileOpen(path) }
        // Opening a file raises the editor to the top of the stack.
        focus(editor)
    }

    func fileSaved() {
        fetchGitStats()
    }

    func activeFileChanged() {
        fetchGitStats()
    }

    func requestClose(_ window: Window) {
        closeWindow(window)
    }

    func runGitCommand(label: String, args: [String]) {
        if maximized != nil { restoreMaximized() }
        // The command window shares the commit editor's layout slot —
        // never show both at once (they would overdraw each other).
        if commitWindow.visible { popWindow(commitWindow) }
        command.workingDirectory = gitPanel.workingDirectory
        command.runCommand(label, args: args)
        recalculateLayout()
        focus(command)
        spaces.markAllDirty()
    }

    /// Any finished git command (pull, push, commit) may have changed the
    /// repository — refresh the panel so the status list stays truthful.
    func gitCommandFinished(_ label: String) {
        gitPanel.refresh()
    }

    func requestCommitMessage() {
        if maximized != nil { restoreMaximized() }
        // Already composing — just refocus, don't wipe the typed message.
        if commitWindow.visible {
            focus(commitWindow)
            spaces.markAllDirty()
            updateStatusBar()
            return
        }
        // The commit editor shares the command window's layout slot —
        // never show both at once (they would overdraw each other).
        if command.visible { popWindow(command) }
        commitWindow.newFile()
        commitWindow.mode = .insert
        commitWindow.headerPlate = HeaderPlate(text: " Commit @ \(gitPanel.currentBranch) ", fg: Theme.orange)
        commitWindow.visible = true
        focus(commitWindow)
        recalculateLayout()
        spaces.markAllDirty()
        updateStatusBar()
    }

    /// `:w`/`:wq`/`:x` in the commit editor confirms the commit.
    func requestCommit() {
        guard let buffer = commitWindow.buffer else { return }
        let message = buffer.getAllText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            reportError("Commit message is empty")
            return
        }
        closeWindow(commitWindow)
        runGitCommand(label: "git commit", args: ["commit", "-m", message])
    }

    func requestRender() {
        recalculateLayout()
        spaces.current.update()
        render()
    }

    /// Shows a transient red message in the status bar. Reuses the editor's
    /// error slot so the message follows the existing lifecycle: any key
    /// press clears it (see handleGlobalKey).
    func reportError(_ message: String) {
        editor.lastError = message
        updateStatusBar()
    }

    func updatePreview(path: String?, highlightLine: Int) {
        preview.loadFile(path, highlightLine: highlightLine)
    }

    private func notifyLSPChange() {
        guard let path = editor.filePath,
              let key = lspClientKey(for: path),
              let client = lspClients[key] else {
            _ = editor.takeLSPPendingChanges()
            return
        }
        guard client.isReady else {
            if !client.isAlive {
                lspClients.removeValue(forKey: key)
                _ = editor.takeLSPPendingChanges()
            }
            return
        }
        let changes = editor.takeLSPPendingChanges()
        guard !changes.isEmpty else { return }
        lspVersion += 1
        let uri = "file://\(path)"
        client.changeDocument(uri: uri, version: lspVersion, changes: changes)
        // Positions in the cached semantic tokens are now stale — schedule a
        // debounced semanticTokens/full re-request for this document.
        pendingTokenRefresh = (path: path, earliest: Date().timeIntervalSince1970 + 0.3)
    }
}
