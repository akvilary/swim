import Foundation

struct FileEntry {
    let name: String
    let path: String
    let isDirectory: Bool
    var isExpanded: Bool = false
    var children: [FileEntry] = []
    var isLoaded: Bool = false
    /// Listing flags, taken when the parent directory is loaded and cached
    /// until it is rescanned (`:fe reset`, create/delete/rename). Filtering
    /// happens at flatten time, so `H` re-filters in memory — no rescan.
    var isIgnored: Bool = false
    var isHidden: Bool = false
}

class FileExplorerWindow: Window {
    override var availableModes: [WindowMode] { [.menu, .command] }
    private var rootEntries: [FileEntry] = []
    private var flatEntries: [(entry: FileEntry, depth: Int)] = []
    private(set) var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var horizontalOffset: Int = 0
    private let horizontalStep: Int = 4
    /// The entry `r` captured for the pending `rename old -> new` command —
    /// disambiguates the bare old name when the tree has duplicates.
    private var pendingRenamePath: String?
    var currentDirectory: String = ""
    /// `H` — the listing filter state: off (default) hides both
    /// dot-prefixed and git-ignored entries; on shows everything. The
    /// toggle re-flattens in memory — the model always carries all
    /// entries with their flags.
    private var showAllEntries = false

    override func update() {
        clear()

        drawHeader(" EXPLORER ", fg: Theme.fgDark)

        let visibleCount = max(0, height - 1)
        for row in 0..<visibleCount {
            let idx = scrollOffset + row
            guard idx < flatEntries.count else { break }
            let (entry, depth) = flatEntries[idx]
            let isSelected = idx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let fg: Color = isSelected ? Theme.fg : Theme.fgDark
            let nameFg: Color = entry.isDirectory ? Theme.blue : fg

            let icon: String
            if entry.isDirectory {
                icon = entry.isExpanded ? "📂" : "📁"
            } else {
                icon = fileIcon(for: entry.name)
            }

            var content: [Cell] = []
            for _ in 0..<(depth * 2) {
                content.append(Cell.colored(" ", fg: fg, bg: bg))
            }
            content.append(Cell.colored(" ", fg: nameFg, bg: bg))
            for c in icon {
                let w = c.displayWidth
                content.append(Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
                if w == 2 {
                    var cont = Cell.colored(" ", fg: nameFg, bg: bg)
                    cont.wideContinuation = true
                    content.append(cont)
                }
            }
            content.append(Cell.colored(" ", fg: nameFg, bg: bg))
            for c in entry.name {
                content.append(Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
            }

            var col = 0
            if horizontalOffset < content.count {
                for i in horizontalOffset..<content.count {
                    if col < width {
                        setCell(row + 1, col, content[i])
                        col += 1
                    }
                }
            }
            while col < width {
                setCell(row + 1, col, Cell.colored(" ", fg: fg, bg: bg))
                col += 1
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "🐦"
        case "js", "ts": return "⚡"
        case "py": return "🐍"
        case "rs": return "⚙"
        case "go": return "🔵"
        case "dart": return "🎯"
        case "md": return "📝"
        case "json": return "📋"
        case "yaml", "yml": return "📋"
        case "toml": return "📋"
        case "txt": return "📄"
        case "lock": return "🔒"
        case "gitignore", "dockerignore": return "🙈"
        case "sh", "bash": return "📜"
        case "css", "scss": return "🎨"
        case "html": return "🌐"
        default: return "  "
        }
    }

    func loadDirectory(_ path: String) {
        currentDirectory = path
        rootEntries = loadEntries(at: path)
        horizontalOffset = 0
        flattenEntries()
        dirty = true
    }

    /// Reveals a file opened from outside the explorer (search result,
    /// jump): expands its ancestor directories and selects the node, so the
    /// tree shows where we are. Does nothing for paths outside the root or
    /// inside hidden directories — those are unreachable while the listing
    /// filter is on (`H` reveals them). When the target exists on disk but
    /// is filtered out of the listing (renamed/created into a dot-name or a
    /// fresh gitignore match), the flat list may have shrunk — the stale
    /// selection clamps onto a real row.
    func reveal(path: String) {
        guard !currentDirectory.isEmpty, path.hasPrefix(currentDirectory + "/") else { return }
        var changed = revealAncestors(&rootEntries, target: path)
        flattenEntries()
        if let idx = flatEntries.firstIndex(where: { $0.entry.path == path }) {
            if selectedIndex != idx {
                selectedIndex = idx
                changed = true
            }
            ensureVisible()
        } else if selectedIndex >= flatEntries.count {
            selectedIndex = max(0, flatEntries.count - 1)
            ensureVisible()
            changed = true
        }
        if changed {
            dirty = true
        }
    }

    /// Expands every directory along the ancestor chain of `target`.
    @discardableResult
    private func revealAncestors(_ entries: inout [FileEntry], target: String) -> Bool {
        var changed = false
        for i in 0..<entries.count {
            guard entries[i].isDirectory, target.hasPrefix(entries[i].path + "/") else { continue }
            if !entries[i].isLoaded {
                entries[i].children = loadEntries(at: entries[i].path, parentIgnored: entries[i].isIgnored)
                entries[i].isLoaded = true
                changed = true
            }
            if !entries[i].isExpanded {
                entries[i].isExpanded = true
                changed = true
            }
            if revealAncestors(&entries[i].children, target: target) {
                changed = true
            }
        }
        return changed
    }

    private func loadEntries(at path: String, parentIgnored: Bool = false) -> [FileEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        let sorted = contents.sorted()
        // Everything under an ignored directory is ignored — git never
        // re-includes inside an excluded subtree — so children of one are
        // flagged for free, without a check-ignore subprocess. Only a
        // directory that is not ignored itself pays the batched git call.
        let ignored: Set<String> = parentIgnored
            ? []
            : Self.ignoredNames(in: path, names: sorted.filter { !$0.hasPrefix(".") })
        var dirs = [FileEntry]()
        var files = [FileEntry]()
        for name in sorted {
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let entry = FileEntry(
                name: name,
                path: fullPath,
                isDirectory: isDir.boolValue,
                isIgnored: parentIgnored || ignored.contains(name),
                isHidden: name.hasPrefix(".")
            )
            if isDir.boolValue { dirs.append(entry) } else { files.append(entry) }
        }
        return dirs + files
    }

    /// Git-ignored names among `names` listed in `directory` — one batched
    /// `git check-ignore --stdin -z` subprocess (NUL-separated both ways, so
    /// exotic path characters survive). Git itself evaluates every pattern
    /// level — the repo .gitignore, nested ones, excludes, negations and
    /// root-anchored rules — and never reports tracked files, which is
    /// exactly the semantics the tree needs. Runs with cwd = the listed
    /// directory, so bare names resolve against the right pattern context.
    /// Exit codes: 0 — some names ignored (stdout lists them), 1 — none;
    /// anything else (no git, not a repository) filters nothing.
    private static func ignoredNames(in directory: String, names: [String]) -> Set<String> {
        guard !names.isEmpty else { return [] }
        let input = names.joined(separator: "\0") + "\0"
        let result = Shell.git(["check-ignore", "--stdin", "-z"], workDir: directory, stdin: input)
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init))
    }

    private func loadChildren(of entry: FileEntry, at index: Int) -> FileEntry {
        var mutable = entry
        if !entry.isLoaded {
            mutable.children = loadEntries(at: entry.path, parentIgnored: entry.isIgnored)
            mutable.isLoaded = true
        }
        mutable.isExpanded = !entry.isExpanded
        return mutable
    }

    private func flattenEntries() {
        flatEntries = []
        flattenRecursive(rootEntries, depth: 0)
    }

    private func flattenRecursive(_ entries: [FileEntry], depth: Int) {
        for entry in entries {
            // The filter lives here, not in loadEntries: flagged entries
            // stay in the model, so `H` re-flattens in memory — instantly,
            // without a rescan or a subprocess.
            if !showAllEntries && (entry.isHidden || entry.isIgnored) { continue }
            flatEntries.append((entry, depth))
            if entry.isDirectory && entry.isExpanded {
                flattenRecursive(entry.children, depth: depth + 1)
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            if selectedIndex < flatEntries.count - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
        case .right: shiftHorizontally(horizontalStep)
        case .left: shiftHorizontally(-horizontalStep)
        case .enter: activateCurrent()
        case .char("l"), .ctrlRight, .ctrl("l"): selectCurrent()
        case .char("h"), .ctrlLeft, .ctrl("h"): collapseCurrent()
        case .char("G"): selectedIndex = max(0, flatEntries.count - 1); ensureVisible(); dirty = true
        case .char("g"): selectedIndex = 0; scrollOffset = 0; dirty = true
        case .char("a"): beginCreate()
        case .char("d"): beginDelete()
        case .char("r"): beginRename()
        case .char("H"): toggleShowAll()
        default: return false
        }
        return true
    }

    private func shiftHorizontally(_ delta: Int) {
        let maxOffset = max(0, maxVisibleContentLength() - width + 1)
        horizontalOffset = max(0, min(horizontalOffset + delta, maxOffset))
        dirty = true
    }

    private func maxVisibleContentLength() -> Int {
        var maxLen = 0
        let visibleCount = max(0, height - 1)
        for row in 0..<visibleCount {
            let idx = scrollOffset + row
            guard idx < flatEntries.count else { break }
            let (entry, depth) = flatEntries[idx]
            let icon = entry.isDirectory ? "📂" : fileIcon(for: entry.name)
            let iconWidth = icon.reduce(0) { $0 + $1.displayWidth }
            let len = depth * 2 + 1 + iconWidth + 1 + entry.name.count
            maxLen = max(maxLen, len)
        }
        return maxLen
    }

    /// Enter: opens a file; toggles a directory — collapsed expands and
    /// selection descends, expanded collapses and selection stays.
    private func activateCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, depth) = flatEntries[selectedIndex]
        guard entry.isDirectory else {
            delegate?.openFile(entry.path)
            return
        }
        toggleExpand(at: selectedIndex)
        descendToFirstChild(depth: depth)
    }

    /// `l` / Ctrl+Right: opens a file; expands a collapsed directory or
    /// descends into an already expanded one — never collapses.
    private func selectCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, depth) = flatEntries[selectedIndex]
        guard entry.isDirectory else {
            delegate?.openFile(entry.path)
            return
        }
        if !entry.isExpanded {
            toggleExpand(at: selectedIndex)
        }
        descendToFirstChild(depth: depth)
    }

    private func descendToFirstChild(depth: Int) {
        let nextIdx = selectedIndex + 1
        if nextIdx < flatEntries.count && flatEntries[nextIdx].depth == depth + 1 {
            selectedIndex = nextIdx
            ensureVisible()
            dirty = true
        }
    }

    private func collapseCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (_, depth) = flatEntries[selectedIndex]

        var targetIdx = selectedIndex
        if depth > 0 {
            var idx = selectedIndex - 1
            while idx >= 0 {
                let (e, d) = flatEntries[idx]
                if d == depth - 1 && e.isDirectory {
                    targetIdx = idx
                    break
                }
                idx -= 1
            }
        }

        selectedIndex = targetIdx
        let (entry, _) = flatEntries[targetIdx]
        if entry.isDirectory && entry.isExpanded {
            toggleExpand(at: targetIdx)
        }
        ensureVisible()
        dirty = true
    }

    private func toggleExpand(at index: Int) {
        let (entry, _) = flatEntries[index]
        let updated = loadChildren(of: entry, at: index)
        let parentPath = entry.path
        updateEntryInTree(&rootEntries, path: parentPath, updated: updated)
        flattenEntries()
        dirty = true
    }

    private func updateEntryInTree(_ entries: inout [FileEntry], path: String, updated: FileEntry) {
        for i in 0..<entries.count {
            if entries[i].path == path { entries[i] = updated; return }
            if entries[i].isDirectory { updateEntryInTree(&entries[i].children, path: path, updated: updated) }
        }
    }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: max(0, height - 1))
    }

    /// `H` — flips the listing filter and re-flattens the tree in memory:
    /// hidden (dot-prefixed) and git-ignored entries stay in the model
    /// with their flags, so no rescan or subprocess happens — the flat
    /// list just includes/excludes the flagged rows. The selection stays
    /// on the same entry when it survives the re-filter, else clamps.
    private func toggleShowAll() {
        let selectedPath = selectedIndex < flatEntries.count ? flatEntries[selectedIndex].entry.path : nil
        showAllEntries.toggle()
        flattenEntries()
        restoreSelection(toPath: selectedPath)
        dirty = true
    }

    /// Restores the selection across a flat-list rebuild: the same path
    /// stays selected when it survives the rebuild, else the index clamps
    /// onto the last row.
    private func restoreSelection(toPath path: String?) {
        if let path, let idx = flatEntries.firstIndex(where: { $0.entry.path == path }) {
            selectedIndex = idx
        } else if flatEntries.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = flatEntries.count - 1
        }
        ensureVisible()
    }

    // MARK: - Create/delete file entries (`a` / `d` → :create / :delete)

    /// Relative path of an absolute tree path (nil outside the root).
    private func relativePath(of absolute: String) -> String? {
        guard absolute.hasPrefix(currentDirectory + "/") else { return nil }
        return String(absolute.dropFirst(currentDirectory.count + 1))
    }

    /// Common `create`/`delete` argument parsing: trims, rejects absolute
    /// paths and `..`; a leading `./` strips away.
    private func relativeParts(_ rawArg: String) -> [String]? {
        let arg = rawArg.trimmingCharacters(in: .whitespaces)
        guard !arg.isEmpty, !arg.hasPrefix("/") else { return nil }
        let relative = arg.hasPrefix("./") ? String(arg.dropFirst(2)) : arg
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts
    }

    /// `a` — opens the command line pre-filled with `create ./<dir>/`
    /// relative to the selection: inside the selected directory, next to
    /// the selected file, or at the tree root when nothing is selected. A
    /// trailing `/` in the typed path creates a directory.
    private func beginCreate() {
        enterCommandMode(prefill: "create \(creationPrefix())")
    }

    /// Directory (relative to the tree root, `./`-prefixed) where `a` will
    /// offer to create: the selected directory itself, the parent of a
    /// selected file, or the root.
    private func creationPrefix() -> String {
        guard selectedIndex < flatEntries.count else { return "./" }
        let (entry, _) = flatEntries[selectedIndex]
        let dirPath = entry.isDirectory
            ? entry.path
            : (entry.path as NSString).deletingLastPathComponent
        if let rel = relativePath(of: dirPath) { return "./\(rel)/" }
        return "./"
    }

    /// `d` — opens the command line pre-filled with `delete ./<selected>`;
    /// the visible command buffer is the confirmation (Enter deletes —
    /// recursively for directories —, Esc cancels).
    private func beginDelete() {
        guard selectedIndex < flatEntries.count else {
            delegate?.reportError("delete: nothing selected")
            return
        }
        let (entry, _) = flatEntries[selectedIndex]
        guard let rel = relativePath(of: entry.path) else { return }
        enterCommandMode(prefill: "delete ./\(rel)\(entry.isDirectory ? "/" : "")")
    }

    override func enterCommandMode(prefill: String = "") {
        // A stale rename capture must not leak into a command typed later
        // by hand — beginRename re-arms it after this call.
        pendingRenamePath = nil
        super.enterCommandMode(prefill: prefill)
    }

    /// `r` — opens the command line pre-filled with `rename ./<path>` of
    /// the selected entry, the caret ready for retyping the name: before
    /// the trailing `/` of a directory, before the `.extension` of a file
    /// (end when there is none). Edit the path in place — backspace over
    /// the name to rename, rewrite the directories to move. Enter renames
    /// the captured entry to the edited path.
    private func beginRename() {
        guard selectedIndex < flatEntries.count else {
            delegate?.reportError("rename: nothing selected")
            return
        }
        let (entry, _) = flatEntries[selectedIndex]
        guard let rel = relativePath(of: entry.path) else { return }
        enterCommandMode(prefill: "rename ./\(rel)\(entry.isDirectory ? "/" : "")")
        pendingRenamePath = entry.path
        var back = 0
        if !entry.isDirectory {
            let ext = (entry.name as NSString).pathExtension
            if !ext.isEmpty { back = ext.count + 1 }
        }
        commandCursorPos = "rename ./".count + rel.count - back
    }

    /// FS command dispatch by first word — O(1) key lookup. Computed (not
    /// stored) so the method references never capture self in a cycle.
    private var fsCommands: [String: (String) -> Void] {
        ["create": createEntry, "delete": deleteEntry, "rename": renameEntry, "fe": feEntry]
    }

    override func executeCommand(_ cmd: String) -> Bool {
        let (name, arg) = Self.splitCommand(cmd)
        guard let handler = fsCommands[name] else { return super.executeCommand(cmd) }
        guard !arg.isEmpty else {
            delegate?.reportError("\(name): missing arguments")
            return true
        }
        handler(arg)
        return true
    }

    /// ("create", "./a b") for "create ./a b"; ("create", "") without args.
    private static func splitCommand(_ cmd: String) -> (name: String, arg: String) {
        guard let spaceIdx = cmd.firstIndex(of: " ") else { return (cmd, "") }
        let arg = String(cmd[cmd.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
        return (String(cmd[..<spaceIdx]), arg)
    }

    /// Creates the entry described by a path relative to the tree root
    /// (`./a/b/file.swift`): a leading `./` strips away, missing
    /// intermediate directories are created; a trailing `/` creates a
    /// directory instead of a file. Errors surface in the status bar via
    /// the shared `reportError` channel; on success the tree rescans
    /// (keeping expansion) and reveals the new entry.
    private func createEntry(_ rawArg: String) {
        guard let parts = relativeParts(rawArg) else {
            delegate?.reportError("create: invalid path")
            return
        }
        let wantsDirectory = rawArg.trimmingCharacters(in: .whitespaces).hasSuffix("/")
        let absolute = (currentDirectory as NSString).appendingPathComponent(parts.joined(separator: "/"))
        let fm = FileManager.default
        guard !fm.fileExists(atPath: absolute) else {
            delegate?.reportError("create: already exists")
            return
        }
        do {
            if wantsDirectory {
                try fm.createDirectory(atPath: absolute, withIntermediateDirectories: true)
            } else {
                let parent = (absolute as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parent) {
                    try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                }
                guard fm.createFile(atPath: absolute, contents: nil) else {
                    delegate?.reportError("create: failed to create file")
                    return
                }
            }
        } catch {
            delegate?.reportError("create: \(error.localizedDescription)")
            return
        }
        reloadPreservingExpansion()
        reveal(path: absolute)
    }

    /// Deletes the entry described by a path relative to the tree root —
    /// recursively when it is a directory. `.` components are rejected
    /// (a sole `.` would resolve to the tree root itself).
    private func deleteEntry(_ rawArg: String) {
        guard let parts = relativeParts(rawArg), !parts.contains(".") else {
            delegate?.reportError("delete: invalid path")
            return
        }
        let absolute = (currentDirectory as NSString).appendingPathComponent(parts.joined(separator: "/"))
        guard FileManager.default.fileExists(atPath: absolute) else {
            delegate?.reportError("delete: not found")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: absolute)
        } catch {
            delegate?.reportError("delete: \(error.localizedDescription)")
            return
        }
        reloadPreservingExpansion()
        if selectedIndex >= flatEntries.count {
            selectedIndex = max(0, flatEntries.count - 1)
        }
        ensureVisible()
    }

    /// `rename <new-path>` renames the entry captured by `r` — its
    /// `./`-path is pre-filled with the caret after the name; the command
    /// line is edited in place. The new side: bare name — rename next to
    /// the captured entry; `./`-path — move from the tree root. `moveItem`
    /// handles files and directories alike. On success the tree rescans
    /// keeping expansion and reveals the new path.
    private func renameEntry(_ rawArg: String) {
        defer { pendingRenamePath = nil }
        guard let old = pendingRenamePath else {
            delegate?.reportError("rename: nothing selected — press r")
            return
        }
        var newArg = rawArg.trimmingCharacters(in: .whitespaces)
        guard !newArg.isEmpty, !newArg.hasPrefix("/") else {
            delegate?.reportError("rename: invalid path")
            return
        }
        while newArg.hasSuffix("/") { newArg.removeLast() }
        let fromRoot = newArg.hasPrefix("./")
        let newRel = fromRoot ? String(newArg.dropFirst(2)) : newArg
        let newParts = newRel.split(separator: "/").map(String.init)
        guard !newParts.isEmpty, !newParts.contains("."), !newParts.contains("..") else {
            delegate?.reportError("rename: invalid path")
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: old) else {
            delegate?.reportError("rename: not found")
            return
        }
        let parent = fromRoot ? currentDirectory : (old as NSString).deletingLastPathComponent
        let new = (parent as NSString).appendingPathComponent(newParts.joined(separator: "/"))
        guard old != new else {
            delegate?.reportError("rename: same path")
            return
        }
        guard !fm.fileExists(atPath: new) else {
            delegate?.reportError("rename: already exists")
            return
        }
        do {
            try fm.moveItem(atPath: old, toPath: new)
        } catch {
            delegate?.reportError("rename: \(error.localizedDescription)")
            return
        }
        reloadPreservingExpansion()
        reveal(path: new)
    }

    /// `:fe reset` — full rescan of the tree from disk with expansion and
    /// selection preserved. The listing flags (git-ignore verdicts) are
    /// taken when a directory is loaded and stay cached until something
    /// rescans it — an externally edited .gitignore or files created
    /// behind swim's back need this command to re-sync.
    private func feEntry(_ rawArg: String) {
        let arg = rawArg.trimmingCharacters(in: .whitespaces)
        guard arg == "reset" else {
            delegate?.reportError("fe: unknown subcommand — try fe reset")
            return
        }
        let selectedPath = selectedIndex < flatEntries.count ? flatEntries[selectedIndex].entry.path : nil
        reloadPreservingExpansion()
        restoreSelection(toPath: selectedPath)
    }

    /// Rescans the tree from disk while keeping the expansion state of
    /// directories that still exist (`loadDirectory` would collapse
    /// everything).
    private func reloadPreservingExpansion() {
        var expanded = Set<String>()
        func collect(_ entries: [FileEntry]) {
            for entry in entries where entry.isDirectory && entry.isExpanded {
                expanded.insert(entry.path)
                collect(entry.children)
            }
        }
        collect(rootEntries)

        func reload(_ path: String, parentIgnored: Bool) -> [FileEntry] {
            loadEntries(at: path, parentIgnored: parentIgnored).map { entry in
                var mutable = entry
                if entry.isDirectory && expanded.contains(entry.path) {
                    mutable.isLoaded = true
                    mutable.isExpanded = true
                    mutable.children = reload(entry.path, parentIgnored: entry.isIgnored)
                }
                return mutable
            }
        }
        rootEntries = reload(currentDirectory, parentIgnored: false)
        flattenEntries()
        dirty = true
    }
}
