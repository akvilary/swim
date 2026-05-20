#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
@preconcurrency
import Foundation

class Application: WindowDelegate {
    private let terminal = Terminal.shared
    private var editorWindow: EditorWindow!
    private var statusBarWindow: StatusBarWindow!
    private var fileExplorerWindow: FileExplorerWindow!
    private var gitPanelWindow: GitPanelWindow!
    private var searchWindow: SearchWindow!
    private var commandWindow: CommandWindow!

    private var windows: [Window] = []
    private var focusIndex: Int = 0
    private var prevFocusIndex: Int = 0
    private var running = true
    private var lspClient: LSPClient?
    private var lspVersion: Int = 0
    private lazy var renderer = Renderer(terminal: terminal)

    init() {
        editorWindow = EditorWindow()
        statusBarWindow = StatusBarWindow()
        fileExplorerWindow = FileExplorerWindow()
        gitPanelWindow = GitPanelWindow()
        searchWindow = SearchWindow()
        commandWindow = CommandWindow()

        gitPanelWindow.delegate = self
        commandWindow.delegate = self
        editorWindow.delegate = self
        fileExplorerWindow.delegate = self
        searchWindow.delegate = self

        windows = [editorWindow, statusBarWindow, fileExplorerWindow, gitPanelWindow, searchWindow, commandWindow]
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
            editorWindow.openFile(path)
        } else {
            editorWindow.newFile()
        }

        let cwd = FileManager.default.currentDirectoryPath
        fileExplorerWindow.visible = true
        gitPanelWindow.visible = false
        searchWindow.visible = false
        commandWindow.visible = false
        fileExplorerWindow.loadDirectory(cwd)
        gitPanelWindow.workingDirectory = cwd

        setupLSP(rootPath: cwd)

        recalculateLayout()
        updateAllWindows()
        render()

        while running {
            pollLSP()
            commandWindow.pollResult()
            searchWindow.pollSearch()
            gitPanelWindow.pollRefresh()
            tickSpinners()
            if terminal.hasResizeEvent {
                terminal.consumeResizeEvent()
                renderer.needsFullRedraw = true
                recalculateLayout()
                markAllDirty()
                updateAllWindows()
                render()
            }
            if terminal.bytesAvailable() {
                if let key = Key.parse(from: terminal) {
                    handleGlobalKey(key)
                }
                updateAllWindows()
                render()
            }
        }

        lspClient?.stop()
        terminal.restore()
    }

    private func pollLSP() {
        guard let client = lspClient, client.hasPendingTokens else { return }
        if let tokens = client.pendingTokens {
            editorWindow.semanticTokens = tokens
            editorWindow.dirty = true
            client.pendingTokens = nil
            updateAllWindows()
            render()
        }
    }

    private var lastSpinnerTick: TimeInterval = 0

    private func tickSpinners() {
        let now = Date().timeIntervalSince1970
        guard now - lastSpinnerTick >= 0.1 else { return }
        var anyDirty = false
        if commandWindow.visible && commandWindow.isRunning {
            commandWindow.spinnerFrame &+= 1
            commandWindow.dirty = true
            anyDirty = true
        }
        if searchWindow.visible && searchWindow.isSearching {
            searchWindow.dirty = true
            anyDirty = true
        }
        if gitPanelWindow.visible && gitPanelWindow.isRefreshing {
            gitPanelWindow.dirty = true
            anyDirty = true
        }
        if anyDirty {
            lastSpinnerTick = now
            updateAllWindows()
            render()
        }
    }

    private func runGitCommandInternal(label: String, args: [String]) {
        commandWindow.workingDirectory = gitPanelWindow.workingDirectory
        commandWindow.runCommand(label, args: args)
        recalculateLayout()
        prevFocusIndex = focusIndex
        focusIndex = windows.firstIndex(where: { $0 === commandWindow }) ?? 0
        markAllDirty()
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

        if let filePath = editorWindow.filePath {
            notifyLSPFileOpen(filePath)
        }
    }

    private func notifyLSPFileOpen(_ path: String) {
        guard let client = lspClient else { return }
        guard let buf = editorWindow.buffer, buf.totalLength < 5_000_000 else { return }
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
        let text = editorWindow.buffer?.getAllText() ?? ""
        client.openDocument(uri: uri, languageId: langId, text: text)
    }

    private func handleGlobalKey(_ key: Key) {
        if editorWindow.lastError != nil {
            editorWindow.lastError = nil
        }
        if editorWindow.mode == .command {
            if editorWindow.handleKey(key) {
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
            if case .normal = editorWindow.mode {
                cycleFocus()
                return
            }
        }

        if case .char(":") = key {
            let focused = focusedWindow()
            if focused !== editorWindow {
                focusIndex = windows.firstIndex(where: { $0 === editorWindow }) ?? 0
                updateFocusStates()
                markAllDirty()
            }
            editorWindow.mode = .command
            editorWindow.commandBuffer = ""
            editorWindow.dirty = true
            updateStatusBar()
            return
        }

        let focused = focusedWindow()
        if focused.handleKey(key) {
            if focused === editorWindow {
                updateStatusBar()
                notifyLSPChange()
            }
        } else if case .escape = key, focused !== editorWindow {
            focused.visible = false
            let restored = windows[prevFocusIndex]
            focusIndex = (restored.visible && prevFocusIndex != focusIndex)
                ? prevFocusIndex
                : windows.firstIndex(where: { $0 === editorWindow }) ?? 0
            recalculateLayout()
            markAllDirty()
        }
    }

    private func toggleFileExplorer() {
        fileExplorerWindow.visible = !fileExplorerWindow.visible
        if fileExplorerWindow.visible && !windows.contains(where: { $0 === fileExplorerWindow && $0.visible }) {
            focusIndex = windows.firstIndex(where: { $0 === fileExplorerWindow }) ?? 0
        }
        recalculateLayout()
        markAllDirty()
    }

    private func toggleGitPanel() {
        gitPanelWindow.visible = !gitPanelWindow.visible
        if gitPanelWindow.visible {
            gitPanelWindow.refresh()
            focusIndex = windows.firstIndex(where: { $0 === gitPanelWindow }) ?? 0
        }
        recalculateLayout()
        markAllDirty()
    }

    private func toggleSearch() {
        if searchWindow.visible {
            searchWindow.visible = false
        } else {
            searchWindow.visible = true
            let cwd = gitPanelWindow.workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : gitPanelWindow.workingDirectory

            if editorWindow.buffer != nil {
                let _ = editorWindow.buffer!.getAllText()
                searchWindow.search(query: "", in: cwd)
            }

            let searchQuery = editorWindow.searchQuery
            if !searchQuery.isEmpty {
                searchWindow.search(query: searchQuery, in: cwd)
            }
            focusIndex = windows.firstIndex(where: { $0 === searchWindow }) ?? 0
        }
        recalculateLayout()
        markAllDirty()
    }

    private func cycleFocus() {
        let focusable = windows.enumerated().filter { $0.element.visible && !($0.element is StatusBarWindow) }
        guard focusable.count > 1 else { return }

        let currentIdx = focusable.firstIndex(where: { $0.offset == focusIndex }) ?? 0
        let nextIdx = (currentIdx + 1) % focusable.count
        prevFocusIndex = focusIndex
        focusIndex = focusable[nextIdx].offset
        markAllDirty()
    }

    private func focusedWindow() -> Window {
        guard focusIndex < windows.count else { return editorWindow }
        let w = windows[focusIndex]
        return w.visible ? w : editorWindow
    }

    private func recalculateLayout() {
        let layout = LayoutManager.calculate(
            terminalWidth: terminal.width,
            terminalHeight: terminal.height,
            showExplorer: fileExplorerWindow.visible,
            showGit: gitPanelWindow.visible,
            showSearch: searchWindow.visible,
            showCommand: commandWindow.visible
        )

        fileExplorerWindow.resize(x: layout.explorer.x, y: layout.explorer.y, width: layout.explorer.width, height: layout.explorer.height)
        editorWindow.resize(x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: layout.editor.height)
        gitPanelWindow.resize(x: layout.git.x, y: layout.git.y, width: layout.git.width, height: layout.git.height)
        searchWindow.resize(x: layout.search.x, y: layout.search.y, width: layout.search.width, height: layout.search.height)
        commandWindow.resize(x: layout.command.x, y: layout.command.y, width: layout.command.width, height: layout.command.height)
        statusBarWindow.resize(x: layout.status.x, y: layout.status.y, width: layout.status.width, height: layout.status.height)
    }

    private func markAllDirty() {
        for window in windows {
            window.dirty = true
        }
        updateFocusStates()
    }

    private func updateFocusStates() {
        for (i, window) in windows.enumerated() {
            window.focused = (i == focusIndex) && window.visible
        }
    }

    private func updateAllWindows() {
        for window in windows {
            if window.visible {
                window.update()
            }
        }
    }

    private func render() {
        let cursorInfo: (window: Window, cursorLine: Int, cursorCol: Int, scrollY: Int, scrollX: Int, lineNumberWidth: Int, mode: EditorMode)? = (
            editorWindow,
            editorWindow.cursorLine,
            editorWindow.cursorCol,
            editorWindow.scrollY,
            editorWindow.scrollX,
            editorWindow.lineNumberWidth(),
            editorWindow.mode
        )
        renderer.render(windows: windows, cursorInfo: cursorInfo)
    }

    private func updateStatusBar() {
        statusBarWindow.modeText = modeString(editorWindow.mode)
        statusBarWindow.fileName = editorWindow.filePath ?? "[No Name]"
        statusBarWindow.cursorLine = editorWindow.cursorLine
        statusBarWindow.cursorCol = editorWindow.cursorCol
        statusBarWindow.totalLines = editorWindow.buffer?.lineCount ?? 0
        statusBarWindow.modified = editorWindow.modified
        statusBarWindow.commandText = editorWindow.commandBuffer
        statusBarWindow.errorMessage = editorWindow.lastError
        if let path = editorWindow.filePath {
            let ext = (path as NSString).pathExtension
            statusBarWindow.fileType = ext.isEmpty ? "" : "[\(ext)]"
        }
        statusBarWindow.dirty = true
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
            if editorWindow.modified { return }
            running = false
        case "forcequit":
            running = false
        case "qa":
            running = false
        case "q":
            if !editorWindow.modified { running = false }
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
        editorWindow.cursorLine = max(0, line - 1)
        editorWindow.ensureCursorVisible()
    }

    func handleEditorCommand(_ cmd: String) {
        handleEditorCommandInternal(cmd)
    }

    func runGitCommand(label: String, args: [String]) {
        runGitCommandInternal(label: label, args: args)
    }

    func requestRender() {
        recalculateLayout()
        updateAllWindows()
        render()
    }

    private func openFileInEditor(_ path: String) {
        editorWindow.openFile(path)
        editorWindow.dirty = true
        updateStatusBar()
        notifyLSPFileOpen(path)
        focusIndex = windows.firstIndex(where: { $0 === editorWindow }) ?? 0
        updateFocusStates()
    }

    private func notifyLSPChange() {
        guard let client = lspClient, let path = editorWindow.filePath,
              let buf = editorWindow.buffer, buf.totalLength < 5_000_000 else { return }
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
