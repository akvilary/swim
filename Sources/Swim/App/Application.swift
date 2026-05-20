#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
@preconcurrency
import Foundation

class Application: WindowDelegate {
    private let terminal = Terminal.shared
    private let windows = Windows()
    private var running = true
    private var lspClient: LSPClient?
    private var lspVersion: Int = 0
    private lazy var renderer = Renderer(terminal: terminal)

    init() {
        windows.assignDelegates(self)
    }

    func run(filePath: String? = nil) {
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

        if let path = filePath {
            windows.editor.openFile(path)
        } else {
            windows.editor.newFile()
        }

        let cwd = FileManager.default.currentDirectoryPath
        windows.fileExplorer.visible = true
        windows.gitPanel.visible = false
        windows.search.visible = false
        windows.command.visible = false
        windows.fileExplorer.loadDirectory(cwd)
        windows.gitPanel.workingDirectory = cwd

        setupLSP(rootPath: cwd)

        windows.focused = windows.editor
        recalculateLayout()
        windows.updateAll()
        render()

        while running {
            pollLSP()
            windows.command.pollResult()
            windows.search.pollSearch()
            windows.gitPanel.pollRefresh()
            tickSpinners()
            if terminal.hasResizeEvent {
                terminal.consumeResizeEvent()
                renderer.needsFullRedraw = true
                recalculateLayout()
                windows.markAllDirty()
                windows.updateAll()
                render()
            }
            if terminal.bytesAvailable() {
                if let key = Key.parse(from: terminal) {
                    handleGlobalKey(key)
                }
                windows.updateAll()
                render()
            }
        }

        lspClient?.stop()
        terminal.restore()
    }

    private func pollLSP() {
        guard let client = lspClient, client.hasPendingTokens else { return }
        if let tokens = client.pendingTokens {
            windows.editor.semanticTokens = tokens
            windows.editor.dirty = true
            client.pendingTokens = nil
            windows.updateAll()
            render()
        }
    }

    private var lastSpinnerTick: TimeInterval = 0

    private func tickSpinners() {
        let now = Date().timeIntervalSince1970
        guard now - lastSpinnerTick >= 0.1 else { return }
        var anyDirty = false
        if windows.command.visible && windows.command.isRunning {
            windows.command.spinnerFrame &+= 1
            windows.command.dirty = true
            anyDirty = true
        }
        if windows.search.visible && windows.search.isSearching {
            windows.search.dirty = true
            anyDirty = true
        }
        if windows.gitPanel.visible && windows.gitPanel.isRefreshing {
            windows.gitPanel.dirty = true
            anyDirty = true
        }
        if anyDirty {
            lastSpinnerTick = now
            windows.updateAll()
            render()
        }
    }

    private func runGitCommandInternal(label: String, args: [String]) {
        windows.command.workingDirectory = windows.gitPanel.workingDirectory
        windows.command.runCommand(label, args: args)
        recalculateLayout()
        windows.prevFocused = windows.focused
        windows.focused = windows.command
        windows.markAllDirty()
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

        if let filePath = windows.editor.filePath {
            notifyLSPFileOpen(filePath)
        }
    }

    private func notifyLSPFileOpen(_ path: String) {
        guard let client = lspClient else { return }
        guard let buf = windows.editor.buffer, buf.totalLength < 5_000_000 else { return }
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
        let text = windows.editor.buffer?.getAllText() ?? ""
        client.openDocument(uri: uri, languageId: langId, text: text)
    }

    private func handleGlobalKey(_ key: Key) {
        if windows.editor.lastError != nil {
            windows.editor.lastError = nil
        }
        if windows.editor.mode == .command {
            if windows.editor.handleKey(key) {
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
            if case .normal = windows.editor.mode {
                cycleFocus()
                return
            }
        }

        if case .char(":") = key {
            if windows.focused !== windows.editor {
                windows.focused = windows.editor
                windows.updateFocusStates()
                windows.markAllDirty()
            }
            windows.editor.mode = .command
            windows.editor.commandBuffer = ""
            windows.editor.dirty = true
            updateStatusBar()
            return
        }

        let focused = windows.focused ?? windows.editor
        if focused.handleKey(key) {
            if focused === windows.editor {
                updateStatusBar()
                notifyLSPChange()
            }
        } else if case .escape = key, focused !== windows.editor {
            focused.visible = false
            if let prev = windows.prevFocused, prev.visible {
                windows.focused = prev
            } else {
                windows.focused = windows.editor
            }
            recalculateLayout()
            windows.markAllDirty()
        }
    }

    private func toggleFileExplorer() {
        windows.fileExplorer.visible = !windows.fileExplorer.visible
        if windows.fileExplorer.visible {
            windows.focused = windows.fileExplorer
        }
        recalculateLayout()
        windows.markAllDirty()
    }

    private func toggleGitPanel() {
        windows.gitPanel.visible = !windows.gitPanel.visible
        if windows.gitPanel.visible {
            windows.gitPanel.refresh()
            windows.focused = windows.gitPanel
        }
        recalculateLayout()
        windows.markAllDirty()
    }

    private func toggleSearch() {
        if windows.search.visible {
            windows.search.visible = false
        } else {
            windows.search.visible = true
            let cwd = windows.gitPanel.workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : windows.gitPanel.workingDirectory
            windows.search.prepareInput(workingDirectory: cwd)
            let searchQuery = windows.editor.searchQuery
            if !searchQuery.isEmpty {
                windows.search.search(query: searchQuery, in: cwd)
            }
            windows.focused = windows.search
        }
        recalculateLayout()
        windows.markAllDirty()
    }

    private func cycleFocus() {
        let focusable = windows.focusable()
        guard focusable.count > 1 else { return }
        guard let currentIdx = focusable.firstIndex(where: { $0 === windows.focused }) else { return }
        windows.prevFocused = windows.focused
        windows.focused = focusable[(currentIdx + 1) % focusable.count]
        windows.markAllDirty()
    }

    private func recalculateLayout() {
        let layout = LayoutManager.calculate(
            terminalWidth: terminal.width,
            terminalHeight: terminal.height,
            showExplorer: windows.fileExplorer.visible,
            showGit: windows.gitPanel.visible,
            showSearch: windows.search.visible,
            showCommand: windows.command.visible
        )

        windows.fileExplorer.resize(x: layout.explorer.x, y: layout.explorer.y, width: layout.explorer.width, height: layout.explorer.height)
        windows.editor.resize(x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: layout.editor.height)
        windows.gitPanel.resize(x: layout.git.x, y: layout.git.y, width: layout.git.width, height: layout.git.height)
        windows.search.resize(x: layout.search.x, y: layout.search.y, width: layout.search.width, height: layout.search.height)
        windows.command.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        windows.statusBar.resize(x: layout.status.x, y: layout.status.y, width: layout.status.width, height: layout.status.height)
    }

    private func render() {
        let cursorInfo: (window: Window, cursorLine: Int, cursorCol: Int, scrollY: Int, scrollX: Int, lineNumberWidth: Int, mode: EditorMode)? = (
            windows.editor,
            windows.editor.cursorLine,
            windows.editor.cursorCol,
            windows.editor.scrollY,
            windows.editor.scrollX,
            windows.editor.lineNumberWidth(),
            windows.editor.mode
        )
        renderer.render(windows: windows.all, cursorInfo: cursorInfo)
    }

    private func updateStatusBar() {
        windows.statusBar.modeText = modeString(windows.editor.mode)
        windows.statusBar.fileName = windows.editor.filePath ?? "[No Name]"
        windows.statusBar.cursorLine = windows.editor.cursorLine
        windows.statusBar.cursorCol = windows.editor.cursorCol
        windows.statusBar.totalLines = windows.editor.buffer?.lineCount ?? 0
        windows.statusBar.modified = windows.editor.modified
        windows.statusBar.commandText = windows.editor.commandBuffer
        windows.statusBar.errorMessage = windows.editor.lastError
        if let path = windows.editor.filePath {
            let ext = (path as NSString).pathExtension
            windows.statusBar.fileType = ext.isEmpty ? "" : "[\(ext)]"
        }
        windows.statusBar.dirty = true
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
            if windows.editor.modified { return }
            running = false
        case "forcequit":
            running = false
        case "qa":
            running = false
        case "q":
            if !windows.editor.modified { running = false }
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
        windows.editor.cursorLine = max(0, line - 1)
        windows.editor.ensureCursorVisible()
    }

    func handleEditorCommand(_ cmd: String) {
        handleEditorCommandInternal(cmd)
    }

    func runGitCommand(label: String, args: [String]) {
        runGitCommandInternal(label: label, args: args)
    }

    func requestRender() {
        recalculateLayout()
        windows.updateAll()
        render()
    }

    private func openFileInEditor(_ path: String) {
        windows.editor.openFile(path)
        windows.editor.dirty = true
        updateStatusBar()
        notifyLSPFileOpen(path)
        windows.focused = windows.editor
        windows.updateFocusStates()
    }

    private func notifyLSPChange() {
        guard let client = lspClient, let path = windows.editor.filePath,
              let buf = windows.editor.buffer, buf.totalLength < 5_000_000 else { return }
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
