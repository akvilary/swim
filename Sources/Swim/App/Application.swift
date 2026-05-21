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
    private var lspClient: LSPClient?
    private var lspVersion: Int = 0
    private lazy var renderer = Renderer(terminal: terminal)

    private let editor = EditorWindow()
    private let statusBar = StatusBarWindow()
    private let fileExplorer = FileExplorerWindow()
    private let gitPanel = GitPanelWindow()
    private let searchResults = SearchResultsWindow()
    private let preview = PreviewWindow()
    private let command = CommandWindow()

    init(filePath: String? = nil) {
        let editorSpace = Space(id: "editor", delegate: self)
        editorSpace.addWindow("fileExplorer", fileExplorer)
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

        if let path = filePath {
            editor.openFile(path)
        } else {
            editor.newFile()
        }

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

        lspClient?.stop()
        terminal.restore()
    }

    private func pollLSP() {
        guard let client = lspClient, client.hasPendingTokens else { return }
        if let tokens = client.pendingTokens {
            editor.semanticTokens = tokens
            editor.dirty = true
            client.pendingTokens = nil
            spaces.current.update()
            render()
        }
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
        if anyDirty {
            lastSpinnerTick = now
            spaces.current.update()
            render()
        }
    }

    private func runGitCommandInternal(label: String, args: [String]) {
        command.workingDirectory = gitPanel.workingDirectory
        command.runCommand(label, args: args)
        recalculateLayout()
        spaces.current.prevFocused = spaces.current.focused
        spaces.current.focused = command
        spaces.markAllDirty()
    }

    private func setupLSP(rootPath: String) {
        let lspPaths = [
            "/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/home/linuxbrew/.linuxbrew/bin/sourcekit-lsp",
            "\(NSHomeDirectory())/.swiftenv/shims/sourcekit-lsp",
        ]

        var lspPath: String?
        for path in lspPaths {
            if FileManager.default.fileExists(atPath: path) {
                lspPath = path
                break
            }
        }

        if lspPath == nil {
            let which = runShell("/usr/bin/which", args: ["sourcekit-lsp"])
            if !which.isEmpty {
                lspPath = which.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let path = lspPath else { return }

        let client = LSPClient()
        client.start(executable: path, rootUri: "file://\(rootPath)")
        lspClient = client

        if let filePath = editor.filePath {
            notifyLSPFileOpen(filePath)
        }
    }

    private func notifyLSPFileOpen(_ path: String) {
        guard let client = lspClient else { return }
        guard let buf = editor.buffer, buf.totalLength < 5_000_000 else { return }
        let uri = "file://\(path)"
        let ext = (path as NSString).pathExtension
        let langId: String
        switch ext {
        case "swift": langId = "swift"
        case "c": langId = "c"
        case "cpp", "cc", "cxx": langId = "cpp"
        case "h": langId = "objective-c"
        case "py": langId = "python"
        case "rs": langId = "rust"
        case "go": langId = "go"
        case "ts": langId = "typescript"
        case "js": langId = "javascript"
        case "dart": langId = "dart"
        default: langId = "plaintext"
        }
        let text = editor.buffer?.getAllText() ?? ""
        client.openDocument(uri: uri, languageId: langId, text: text)
    }

    private func handleGlobalKey(_ key: Key) {
        if editor.lastError != nil {
            editor.lastError = nil
        }
        if editor.mode == .command {
            if editor.handleKey(key) {
                updateStatusBar()
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
            showCommand: command.visible
        )

        fileExplorer.resize(x: layout.explorer.x, y: layout.explorer.y, width: layout.explorer.width, height: layout.explorer.height)
        editor.resize(x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: layout.editor.height)
        gitPanel.resize(x: layout.git.x, y: layout.git.y, width: layout.git.width, height: layout.git.height)
        searchResults.resize(x: layout.searchResults.x, y: layout.searchResults.y, width: layout.searchResults.width, height: layout.searchResults.height)
        preview.resize(x: layout.preview.x, y: layout.preview.y, width: layout.preview.width, height: layout.preview.height)
        command.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        statusBar.resize(x: layout.status.x, y: layout.status.y, width: layout.status.width, height: layout.status.height)
    }

    private func render() {
        let cursorInfo: (window: Window, cursorLine: Int, cursorCol: Int, scrollY: Int, scrollX: Int, lineNumberWidth: Int, mode: EditorMode)? = (
            editor,
            editor.cursorLine,
            editor.cursorCol,
            editor.scrollY,
            editor.scrollX,
            editor.lineNumberWidth(),
            editor.mode
        )
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

    private func handleEditorCommandInternal(_ cmd: String) {
        switch cmd {
        case "quit":
            if editor.modified { return }
            running = false
        case "forcequit":
            running = false
        case "qa":
            running = false
        case "q":
            if !editor.modified { running = false }
        case "q!":
            running = false
        default:
            break
        }
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

    func handleEditorCommand(_ cmd: String) {
        handleEditorCommandInternal(cmd)
    }

    func runGitCommand(label: String, args: [String]) {
        runGitCommandInternal(label: label, args: args)
    }

    func requestRender() {
        recalculateLayout()
        spaces.current.update()
        render()
    }

    func updatePreview(path: String?, highlightLine: Int) {
        preview.loadFile(path, highlightLine: highlightLine)
    }

    private func openFileInEditor(_ path: String) {
        editor.openFile(path)
        editor.dirty = true
        updateStatusBar()
        notifyLSPFileOpen(path)
        spaces.current.focused = editor
        spaces.current.updateFocusStates()
    }

    private func notifyLSPChange() {
        guard let client = lspClient, let path = editor.filePath,
              let buf = editor.buffer, buf.totalLength < 5_000_000 else { return }
        lspVersion += 1
        let uri = "file://\(path)"
        let text = buf.getAllText()
        client.changeDocument(uri: uri, version: lspVersion, text: text)
    }

    private func runShell(_ cmd: String, args: [String] = []) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
