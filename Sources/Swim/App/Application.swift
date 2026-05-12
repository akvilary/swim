#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
@preconcurrency
import Foundation

class Application {
    private let terminal = Terminal.shared
    private var editorWindow: EditorWindow!
    private var statusBarWindow: StatusBarWindow!
    private var fileExplorerWindow: FileExplorerWindow!
    private var gitPanelWindow: GitPanelWindow!
    private var searchWindow: SearchWindow!

    private var windows: [Window] = []
    private var focusIndex: Int = 0
    private var running = true
    private var prevScreenCells: [Int: [Int: Cell]] = [:]
    private var lspClient: LSPClient?
    private var lspVersion: Int = 0
    private var needsFullRedraw = true

    init() {
        editorWindow = EditorWindow()
        statusBarWindow = StatusBarWindow()
        fileExplorerWindow = FileExplorerWindow()
        gitPanelWindow = GitPanelWindow()
        searchWindow = SearchWindow()

        windows = [editorWindow, statusBarWindow, fileExplorerWindow, gitPanelWindow, searchWindow]

        editorWindow.onCommand = { [weak self] cmd in
            self?.handleEditorCommand(cmd)
        }

        fileExplorerWindow.onFileSelect = { [weak self] path in
            self?.openFileInEditor(path)
        }

        searchWindow.onResultSelect = { [weak self] path, line in
            self?.openFileAtLine(path, line: line)
        }
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
        fileExplorerWindow.loadDirectory(cwd)
        gitPanelWindow.workingDirectory = cwd

        setupLSP(rootPath: cwd)

        recalculateLayout()
        render()

        while running {
            pollLSP()
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

        let focused = focusedWindow()
        if focused.handleKey(key) {
            if focused === editorWindow {
                updateStatusBar()
                notifyLSPChange()
            }
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
        focusIndex = focusable[nextIdx].offset
        markAllDirty()
    }

    private func focusedWindow() -> Window {
        guard focusIndex < windows.count else { return editorWindow }
        let w = windows[focusIndex]
        return w.visible ? w : editorWindow
    }

    private func recalculateLayout() {
        let w = max(10, terminal.width)
        let h = max(5, terminal.height)
        let statusH = 1

        var editorX = 0
        var editorW = w
        var explorerW = 0

        if fileExplorerWindow.visible {
            explorerW = min(28, w / 4)
            editorX = explorerW
            editorW = w - explorerW
        }

        var gitH = 0
        var searchH = 0
        if gitPanelWindow.visible {
            gitH = min(15, h / 3)
        }
        if searchWindow.visible {
            searchH = min(15, h / 3)
        }

        let editorH = max(1, h - statusH - gitH - searchH)

        fileExplorerWindow.resize(x: 0, y: 0, width: explorerW, height: editorH)
        editorWindow.resize(x: editorX, y: 0, width: editorW, height: editorH)

        var bottomY = editorH
        if gitPanelWindow.visible {
            gitPanelWindow.resize(x: 0, y: bottomY, width: w, height: gitH)
            bottomY += gitH
        }
        if searchWindow.visible {
            searchWindow.resize(x: 0, y: bottomY, width: w, height: searchH)
        }

        statusBarWindow.resize(x: 0, y: h - statusH, width: w, height: statusH)
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

    private var termFG: Color = .default
    private var termBG: Color = .default
    private var termBold: Bool = false
    private var termDim: Bool = false
    private var termUnderline: Bool = false
    private var termReverse: Bool = false

    private func render() {
        updateAllWindows()

        for window in windows {
            guard window.visible else { continue }

            for row in 0..<window.height {
                let screenRow = window.y + row
                if screenRow >= terminal.height { continue }

                for col in 0..<window.width {
                    let screenCol = window.x + col
                    if screenCol >= terminal.width { continue }

                    let cell = window.getCell(row, col)

                    if cell.wideContinuation { continue }

                    if prevScreenCells[screenRow]?[screenCol] != cell {
                        if prevScreenCells[screenRow] == nil {
                            prevScreenCells[screenRow] = [:]
                        }

                        terminal.moveCursor(row: screenRow, col: screenCol)

                        if termFG != cell.fg { terminal.setFG(cell.fg); termFG = cell.fg }
                        if termBG != cell.bg { terminal.setBG(cell.bg); termBG = cell.bg }
                        if termBold != cell.bold { terminal.setBold(cell.bold); termBold = cell.bold }
                        if termDim != cell.dim { terminal.setDim(cell.dim); termDim = cell.dim }
                        if termUnderline != cell.underline { terminal.setUnderline(cell.underline); termUnderline = cell.underline }
                        if termReverse != cell.reverse { terminal.setReverse(cell.reverse); termReverse = cell.reverse }

                        terminal.writeChar(cell.char)

                        prevScreenCells[screenRow]![screenCol] = cell

                        if isWideChar(cell.char), screenCol + 1 < terminal.width {
                            if prevScreenCells[screenRow] == nil { prevScreenCells[screenRow] = [:] }
                            prevScreenCells[screenRow]![screenCol + 1] = window.getCell(row, col + 1)
                        }
                    }
                }
            }
        }

        terminal.flush()
    }

    private func isWideChar(_ c: Character) -> Bool {
        let s = String(c)
        let utf8 = s.utf8
        guard let first = utf8.first else { return false }
        if first >= 0xF0 { return true }
        return false
    }

    private func updateStatusBar() {
        statusBarWindow.modeText = modeString(editorWindow.mode)
        statusBarWindow.fileName = editorWindow.filePath ?? "[No Name]"
        statusBarWindow.cursorLine = editorWindow.cursorLine
        statusBarWindow.cursorCol = editorWindow.cursorCol
        statusBarWindow.totalLines = editorWindow.buffer?.lineCount ?? 0
        statusBarWindow.modified = editorWindow.modified
        statusBarWindow.commandText = editorWindow.commandBuffer
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
        case .command: return "COMMAND"
        }
    }

    private func handleEditorCommand(_ cmd: String) {
        switch cmd {
        case "quit":
            if editorWindow.modified {
                return
            }
            running = false
        case "forcequit":
            running = false
        default:
            break
        }
    }

    private func openFileInEditor(_ path: String) {
        editorWindow.openFile(path)
        editorWindow.dirty = true
        updateStatusBar()
        notifyLSPFileOpen(path)
        focusIndex = windows.firstIndex(where: { $0 === editorWindow }) ?? 0
        updateFocusStates()
    }

    private func openFileAtLine(_ path: String, line: Int) {
        openFileInEditor(path)
        editorWindow.cursorLine = max(0, line - 1)
        editorWindow.ensureCursorVisible()
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
