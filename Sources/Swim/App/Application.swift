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

    private let editor = EditorWindow()
    private let statusBar = StatusBarWindow()
    private let tabBar = TabBarWindow()
    private let fileExplorer = FileExplorerWindow()
    private let gitPanel = GitPanelWindow()
    private let searchResults = SearchResultsWindow()
    private let preview = PreviewWindow()
    private let command = CommandWindow()

    init(filePath: String? = nil) {
        let editorSpace = Space(id: "editor", delegate: self)
        editorSpace.addWindow("fileExplorer", fileExplorer)
        editorSpace.addWindow("tabBar", tabBar)
        editorSpace.addWindow("editor", editor)
        editorSpace.addWindow("gitPanel", gitPanel)
        editorSpace.addWindow("command", command)
        editorSpace.addWindow("statusBar", statusBar)

        let searchSpace = Space(id: "search", delegate: self)
        searchSpace.addWindow("searchResults", searchResults)
        searchSpace.addWindow("preview", preview)
        searchSpace.addWindow("statusBar", statusBar)

        spaces.addSpace(editorSpace)
        spaces.addSpace(searchSpace)
        spaces.switchTo("editor")

        tabBar.tabsSource = editor
        tabBar.visible = true

        if let path = filePath, !isDirectory(path) {
            editor.openFile(path)
        } else {
            // No file argument (or a directory like `swim .`): start with a
            // pristine [No Name] tab; the first opened file replaces it.
            editor.newFile()
        }
        updateStatusBar()

        let cwd = FileManager.default.currentDirectoryPath
        fileExplorer.visible = true
        editor.visible = true
        statusBar.visible = true
        fileExplorer.loadDirectory(cwd)
        gitPanel.workingDirectory = cwd

        setupLSP(rootPath: cwd)

        spaces.current.focused = editor
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
                    handleGlobalKey(key)
                }
                spaces.current.update()
                render()
            }
        }

        for (_, client) in lspClients { client.stop() }
        terminal.restore()
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
        if path != editor.filePath {
            openFileInEditor(path)
        }
        editor.goToPosition(line: line, colUtf16: colUtf16)
        if spaces.current.id != "editor" {
            switchToSpace("editor")
        }
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

    /// Builds basedpyright initializationOptions with extraPaths taken from
    /// pytest's `[tool.pytest.ini_options].pythonpath` (pyproject.toml).
    /// Returns nil when the server has its own config ([tool.basedpyright],
    /// [tool.pyright] or pyrightconfig.json) — that config must win.
    private func pythonInitializationOptions(rootPath: String) -> [String: Any]? {
        let pyprojectPath = rootPath + "/pyproject.toml"
        guard let text = try? String(contentsOfFile: pyprojectPath, encoding: .utf8) else { return nil }
        guard !Self.tomlHasSection(text, "tool.basedpyright"),
              !Self.tomlHasSection(text, "tool.pyright"),
              !FileManager.default.fileExists(atPath: rootPath + "/pyrightconfig.json") else { return nil }
        let extra = Self.tomlStringArray(in: text, section: "tool.pytest.ini_options", key: "pythonpath")
        guard !extra.isEmpty else { return nil }
        let absolute = extra.map { $0.hasPrefix("/") ? $0 : rootPath + "/" + $0 }
        return ["settings": [["uri": "file://\(rootPath)", "settings": ["extraPaths": absolute]]]]
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
        if editor.mode == .command {
            if editor.handleKey(key) {
                updateStatusBar()
                notifyLSPChange()
            }
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
        case .ctrl("c"):
            running = false
            return
        case .ctrl("x"):
            closeCurrentTab(force: false)
            return
        case .ctrl("z"):
            closeOtherTabs()
            return
        default:
            break
        }

        if case .tab = key {
            if case .normal = editor.mode {
                cycleFocus()
                return
            }
        }

        if case .char(":") = key {
            if spaces.current.focused !== editor {
                spaces.current.focused = editor
                spaces.current.updateFocusStates()
                spaces.markAllDirty()
            }
            editor.mode = .command
            editor.commandBuffer = ""
            editor.dirty = true
            updateStatusBar()
            return
        }

        let focused = spaces.current.focused ?? editor
        if focused.handleKey(key) {
            if focused === editor {
                updateStatusBar()
                notifyLSPChange()
            }
        } else if case .escape = key, focused !== editor {
            if spaces.current.id != "editor" {
                switchToSpace("editor")
                spaces.current.focused = editor
                spaces.current.updateFocusStates()
            } else {
                focused.visible = false
                if let prev = spaces.current.prevFocused, prev.visible {
                    spaces.current.focused = prev
                } else {
                    spaces.current.focused = editor
                }
                recalculateLayout()
                spaces.markAllDirty()
            }
        }
    }

    private func toggleFileExplorer() {
        fileExplorer.visible = !fileExplorer.visible
        if fileExplorer.visible {
            spaces.current.focused = fileExplorer
        }
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func toggleGitPanel() {
        gitPanel.visible = !gitPanel.visible
        if gitPanel.visible {
            gitPanel.refresh()
            spaces.current.focused = gitPanel
        }
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func toggleSearch() {
        if spaces.current.id == "search" {
            switchToSpace("editor")
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
            spaces.current.focused = searchResults
        }
    }

    private func switchToSpace(_ spaceId: String) {
        spaces.switchTo(spaceId)
        recalculateLayout()
        spaces.markAllDirty()
    }

    private func cycleFocus() {
        let focusable = spaces.current.focusable()
        guard focusable.count > 1 else { return }
        guard let currentIdx = focusable.firstIndex(where: { $0 === spaces.current.focused }) else { return }
        spaces.current.prevFocused = spaces.current.focused
        spaces.current.focused = focusable[(currentIdx + 1) % focusable.count]
        spaces.markAllDirty()
    }

    private func recalculateLayout() {
        let layout = LayoutManager.calculate(
            terminalWidth: terminal.width,
            terminalHeight: terminal.height,
            space: spaces.current.id,
            showExplorer: fileExplorer.visible,
            showGit: gitPanel.visible,
            showCommand: command.visible,
            showTabBar: true
        )

        fileExplorer.resize(x: layout.explorer.x, y: layout.explorer.y, width: layout.explorer.width, height: layout.explorer.height)
        tabBar.resize(x: layout.tabbar.x, y: layout.tabbar.y, width: layout.tabbar.width, height: layout.tabbar.height)
        editor.resize(x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: layout.editor.height)
        gitPanel.resize(x: layout.git.x, y: layout.git.y, width: layout.git.width, height: layout.git.height)
        searchResults.resize(x: layout.searchResults.x, y: layout.searchResults.y, width: layout.searchResults.width, height: layout.searchResults.height)
        preview.resize(x: layout.preview.x, y: layout.preview.y, width: layout.preview.width, height: layout.preview.height)
        command.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        statusBar.resize(x: layout.status.x, y: layout.status.y, width: layout.status.width, height: layout.status.height)
    }

    private func render() {
        var cursorInfo: CursorRenderInfo?
        if editor.visible && editor.mode == .insert {
            let screenRow = editor.cursorLine - editor.scrollY
            let screenCol = editor.cursorCol - editor.scrollX
            let lnW = editor.lineNumberWidth()
            if screenRow >= 0 && screenRow < editor.height && screenCol >= 0 && screenCol + lnW < editor.width {
                cursorInfo = CursorRenderInfo(row: editor.y + screenRow, col: editor.x + lnW + screenCol, shape: 5, visible: true)
            }
        }
        renderer.render(windows: spaces.current.visibleWindows, cursorInfo: cursorInfo)
    }

    private func updateStatusBar() {
        statusBar.modeText = modeString(editor.mode)
        statusBar.fileName = editor.filePath ?? "[No Name]"
        statusBar.cursorLine = editor.cursorLine
        statusBar.cursorCol = editor.cursorCol
        statusBar.totalLines = editor.buffer?.lineCount ?? 0
        statusBar.modified = editor.modified
        statusBar.commandText = editor.commandBuffer
        statusBar.errorMessage = editor.lastError
        tabBar.dirty = true
        if let path = editor.filePath {
            let ext = (path as NSString).pathExtension
            statusBar.fileType = ext.isEmpty ? "" : "[\(ext)]"
        }
        statusBar.dirty = true
    }

    private func modeString(_ mode: EditorMode) -> String {
        switch mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "VISUAL LINE"
        case .command: return "COMMAND"
        }
    }

    func handleEditorCommand(_ cmd: String) {
        switch cmd {
        case "quit", "q", "bd":
            closeCurrentTab(force: false)
        case "forcequit", "bd!":
            closeCurrentTab(force: true)
        case "qa":
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
        updateStatusBar()
        if wasLast { running = false }
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
        openFileInEditor(path)
        editor.cursorLine = max(0, line - 1)
        editor.ensureCursorVisible()
        if spaces.current.id != "editor" {
            switchToSpace("editor")
        }
    }

    private func openFileInEditor(_ path: String) {
        let isNew = editor.openFile(path)
        editor.dirty = true
        updateStatusBar()
        if isNew { notifyLSPFileOpen(path) }
        spaces.current.focused = editor
        spaces.current.updateFocusStates()
    }

    func runGitCommand(label: String, args: [String]) {
        command.workingDirectory = gitPanel.workingDirectory
        command.runCommand(label, args: args)
        recalculateLayout()
        spaces.current.prevFocused = spaces.current.focused
        spaces.current.focused = command
        spaces.markAllDirty()
    }

    func requestRender() {
        recalculateLayout()
        spaces.current.update()
        render()
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
