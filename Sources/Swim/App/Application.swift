#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
@preconcurrency
import Foundation
import SwimCore

class Application: WindowDelegate {
    private let terminal = Terminal.shared
    private let spaces = Spaces()
    private var running = true
    private var lspClients: [String: LSPClient] = [:]
    private var pendingTokenRefresh: (path: String, earliest: TimeInterval)?
    private lazy var renderer = Renderer(terminal: terminal)

    /// Git info for the status bar: branch + added/deleted lines of the
    /// working tree (git diff HEAD --numstat) and of the open file —
    /// fetched in the background on file save / open / tab switch.
    /// The same fetch feeds the git-driven decorations: line-level
    /// status of the open file (editor gutter numbers) and the
    /// per-file marks of the explorer (name coloring).
    private struct GitStats {
        var branch: String?
        var added = 0
        var deleted = 0
        var fileAdded = 0
        var fileDeleted = 0
        /// The file the line-level status below was computed for (the
        /// active file at request time); the result is applied to its
        /// tab even if the user switched away mid-fetch.
        var filePath: String?
        var fileIsNew = false
        var fileStaged: Set<Int> = []
        var fileUnstaged: Set<Int> = []
        /// Explorer name marks by absolute path (the explorer's own view
        /// of the tree), classified by the shared SwimCore
        /// `GitChangeClass`.
        var marks: [String: GitChangeClass] = [:]
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
                ? BufferManager.normalize(rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
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

            // Full status through the shared SwimCore parser: feeds the
            // explorer name marks (every changed file) and the open
            // file's XY class. Porcelain paths are repo-root-relative;
            // `--untracked-files=all` lists each file inside an
            // untracked directory instead of the collapsed `?? dir/`
            // entry — the tree shows files, not the directory mark.
            let porcelain = Shell.git(["status", "--porcelain", "-z", "--untracked-files=all"],
                                      workDir: dir).stdout

            // Two coordinate systems meet here: git reports repo-root-
            // relative paths (root — as git resolves it, possibly past a
            // symlinked cwd), while the explorer tree and editor paths
            // live in the user's view of `dir`. Marks are keyed in the
            // explorer's view — dir + the path's remainder below dir —
            // so both a subdirectory root and a symlinked root resolve;
            // the fallback (dir not under root) keys by the repo path.
            let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let realDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            let realFile = filePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let subRel: String?
            if realDir == realRoot {
                subRel = ""
            } else if realDir.hasPrefix(realRoot + "/") {
                subRel = String(realDir.dropFirst(realRoot.count))
            } else {
                subRel = nil
            }

            var openXY: (x: Character, y: Character)?
            for entry in Porcelain.parse(porcelain) {
                let key: String?
                if let subRel {
                    if subRel.isEmpty {
                        key = dir + "/" + entry.path
                    } else if entry.path.hasPrefix(subRel.dropFirst() + "/") {
                        key = dir + "/" + String(entry.path.dropFirst(subRel.count))
                    } else {
                        key = nil  // elsewhere in the repo — not in the tree
                    }
                } else {
                    key = root + "/" + entry.path
                }
                if let filePath, let realFile,
                   root + "/" + entry.path == filePath || realRoot + "/" + entry.path == realFile {
                    openXY = (entry.x, entry.y)
                }
                if let key, let cls = entry.changeClass {
                    stats.marks[key] = cls
                }
            }

            guard let filePath, let realFile else { return stats }
            stats.filePath = filePath
            // Pathspec relative to the repo root, resolved through
            // symlinks first (git's root is the resolved one); the
            // view-relative fallback covers roots git reports verbatim.
            guard let rel = realFile.hasPrefix(realRoot + "/")
                ? String(realFile.dropFirst(realRoot.count + 1))
                : filePath.hasPrefix(root + "/") ? String(filePath.dropFirst(root.count + 1)) : nil
            else { return stats }

            // Green in its entirety only when untracked — a staged add
            // is staged through and through (the cached diff covers the
            // whole file), AM keeps its unstaged hunks on the staged base.
            let isNewFile = openXY != nil && openXY!.x == "?" && openXY!.y == "?"
            stats.fileIsNew = isNewFile

            // Untracked files never appear in `git diff` — for the open
            // file show its whole content as additions.
            if let xy = openXY, xy.x == "?" && xy.y == "?",
               let text = try? String(contentsOfFile: filePath, encoding: .utf8),
               !text.isEmpty {
                stats.fileAdded = text.split(separator: "\n", omittingEmptySubsequences: false).count
            }

            // Line-level hunks for the gutter. Unstaged (working tree vs
            // index) is always fetched — a staged add can carry worktree
            // edits on top (AM). Staged hunks are fetched for everything
            // tracked-or-staged; only an untracked file is green in its
            // entirety.
            let spec = ":(top,literal)" + rel
            stats.fileUnstaged = HunkLines.changedLines(
                Shell.git(["diff", "--unified=0", "--", spec], workDir: dir)
                    .stdout.split(separator: "\n", omittingEmptySubsequences: false))
            if !isNewFile {
                stats.fileStaged = HunkLines.changedLines(
                    Shell.git(["diff", "--cached", "--unified=0", "--", spec], workDir: dir)
                        .stdout.split(separator: "\n", omittingEmptySubsequences: false))
            }
            return stats
        }
    }

    private func pollGitStats() {
        guard let stats = gitStatsTask.consume() else { return }
        let refetchQueued = gitStatsState == .runningQueued
        gitStatsState = .idle

        var anyChange = false
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
            anyChange = true
        }

        // Editor git gutter: the fetch ran for one file; the result
        // lands on its tab even when the user switched away mid-fetch
        // (the switch itself started a fresh fetch for the new file).
        if let path = stats.filePath {
            let status = GitLineStatus(isNewFile: stats.fileIsNew,
                                       staged: stats.fileStaged,
                                       unstaged: stats.fileUnstaged)
            if editor.applyGitLineStatus(status, for: path) {
                anyChange = true
            }
        }
        if fileExplorer.setGitMarks(stats.marks) {
            anyChange = true
        }

        if anyChange {
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
            for pending in client.takePendingDiagnostics() {
                // A publish tagged with a version older than what we last
                // sent describes superseded content — drop it instead of
                // flashing stale underlines at the user.
                if let version = pending.version,
                   let lastSent = client.lastSentVersion(for: pending.uri),
                   version < lastSent {
                    continue
                }
                let path = pathFromUri(pending.uri)
                guard let target = editor.findBuffer(forNormalizedPath: path) else { continue }
                if editor.applyDiagnostics(pending.diagnostics, to: target) {
                    updateStatusBar()
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
            client.start(executable: path, arguments: ["--stdio"], rootUri: "file://\(rootPath)")
            if let settings = pythonWorkspaceSettings(rootPath: rootPath) {
                client.applyWorkspaceSettings(settings)
            }
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

    /// Builds basedpyright workspace settings, pushed via
    /// workspace/didChangeConfiguration (the only settings channel
    /// basedpyright reads — its initializationOptions carries nothing but
    /// disablePullDiagnostics). The baseline matches pyright's defaults:
    /// basedpyright alone defaults typeCheckingMode to "all", whose
    /// reportUnknown*/annotation rules flood the diagnostics swim now
    /// renders; openFilesOnly keeps large monorepos from burning a CPU
    /// core analyzing files the user never opened. Returns nil when the
    /// server has its own config ([tool.basedpyright], [tool.pyright] or
    /// pyrightconfig.json) — that config must win. extraPaths is NOT
    /// forwarded: basedpyright accepts it only from the config file, so
    /// projects needing search paths write them into pyproject.toml.
    private func pythonWorkspaceSettings(rootPath: String) -> [String: Any]? {
        if let text = try? String(contentsOfFile: rootPath + "/pyproject.toml", encoding: .utf8) {
            guard !Self.tomlHasSection(text, "tool.basedpyright"),
                  !Self.tomlHasSection(text, "tool.pyright"),
                  !FileManager.default.fileExists(atPath: rootPath + "/pyrightconfig.json") else { return nil }
        }
        return ["pyright": ["typeCheckingMode": "standard", "diagnosticMode": "openFilesOnly"]]
    }

    /// True when the TOML text contains the `[section]` header.
    private static func tomlHasSection(_ text: String, _ section: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { return false }
            return t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == section
        }
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
        // Closing the command window while git waits for a credential —
        // cancel the operation instead of leaving it hanging forever.
        if target === command { command.cancelPendingCredential() }
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
            // Opening the panel signals interest in git state — the
            // decorations (gutter lines, explorer marks) may be stale
            // after changes made outside swim.
            fetchGitStats()
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
        if focused is EditorWindow || focused == nil {
            if let diag = editor.cursorDiagnostic() {
                statusBar.diagnosticMessage = (text: diag.message, severity: diag.severity)
            } else {
                statusBar.diagnosticMessage = nil
            }
        } else {
            statusBar.diagnosticMessage = nil
        }
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

    /// A stage/unstage/discard from the git panel or a create/delete/
    /// rename in the explorer changed the worktree — refetch the
    /// git-driven decorations (status bar stats, editor gutter lines,
    /// explorer name marks).
    func gitWorktreeChanged() {
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
    /// repository — refresh the panel so the status list stays truthful,
    /// refetch the git-driven decorations (a commit clears the staged
    /// marks/lines), and sweep clean tabs: a pull merge may have
    /// rewritten their files.
    func gitCommandFinished(_ label: String) {
        fetchGitStats()
        gitPanel.refresh()
        for fresh in editor.tabs.reloadChangedOnDisk() {
            applyBufferReload(fresh)
        }
    }

    /// Any finished terminal command may have changed the open file,
    /// renamed something or switched the git branch — resync the status
    /// bar stats (branch/diff, fetched in the background) and the git
    /// panel, the same contract as git commands run through CommandWindow;
    /// the sweep picks up files the command rewrote (e.g. git checkout
    /// typed into the terminal).
    func terminalCommandFinished() {
        fetchGitStats()
        gitPanel.refresh()
        for fresh in editor.tabs.reloadChangedOnDisk() {
            applyBufferReload(fresh)
        }
    }

    /// A git-panel discard rewrote a working-tree file: reload any clean
    /// editor tab for it (modified buffers keep the user's unsaved
    /// edits), then resync stats and LSP with the new content.
    func fileChangedOnDisk(_ path: String) {
        guard let fresh = editor.tabs.reloadIfClean(path: path) else { return }
        applyBufferReload(fresh)
    }

    /// The [R]eload answer of the changed-on-disk confirm prompt: the
    /// user deliberately discards the active tab's edits. A file gone
    /// from disk cannot be reloaded — the edits stay and the user hears
    /// why (vim's E211).
    func reloadActiveBufferDiscardingEdits() {
        guard let path = editor.filePath else { return }
        guard let fresh = editor.tabs.reloadDiscardingEdits(path: path) else {
            reportError("File no longer exists on disk — edits kept")
            return
        }
        applyBufferReload(fresh)
    }

    /// Common post-reload resync for a swapped-in fresh buffer: repaint,
    /// refresh stats, and hand the LSP server the full new content (a
    /// contentChange without a range replaces the whole document).
    private func applyBufferReload(_ fresh: EditorBuffer) {
        editor.bufferReloaded(fresh)
        editor.dirty = true
        tabBar.dirty = true
        updateStatusBar()
        fetchGitStats()
        guard let path = fresh.filePath,
              let key = lspClientKey(for: path),
              let client = lspClients[key], client.isReady else { return }
        client.reloadDocument(uri: "file://\(path)",
                              text: fresh.buffer.getAllText())
    }

    func requestCommitMessage(prefill: String) {
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
        // `C` — prefill with the last commit's message. Inserted as
        // initial content (no undo entry, not modified): `u` can't wipe
        // the template, `:q` stays quota-free. Cursor lands at the end
        // of the text so typing appends.
        if !prefill.isEmpty, let buf = commitWindow.buffer {
            buf.insert(prefill, at: 0)
            let lastLine = max(0, buf.lineCount - 1)
            commitWindow.goToPosition(line: lastLine, colUtf16: buf.getLine(lastLine).utf16.count)
        }
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
        client.changeDocument(uri: "file://\(path)", changes: changes)
        // Positions in the cached semantic tokens are now stale — schedule a
        // debounced semanticTokens/full re-request for this document.
        pendingTokenRefresh = (path: path, earliest: Date().timeIntervalSince1970 + 0.3)
    }
}
