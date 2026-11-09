import Foundation
import SwimCore

class FileExplorerWindow: Window {
    override var availableModes: [WindowMode] { [.menu, .command] }

    /// The shared tree-list machinery: rows (FileTree.flatten over
    /// the tree + the expansion state), cursor, scroll, horizontal
    /// shift, git name-marks — one component with the search results
    /// window (TreeListView.swift). The tree rides in it as a
    /// synthetic root `FileTreeNode` (path = the working directory,
    /// children = its contents; the root itself is never a row).
    /// Born with the listing filter ON: hidden (dot-prefixed) and
    /// git-ignored entries stay out of the rows until `H` flips the
    /// state — the controller's filter IS the state, no mirror flag
    /// on the window to drift out of sync (the missing initial
    /// install was exactly that drift: the filter used to engage
    /// only after two `H` presses).
    private let list: TreeListController = {
        let list = TreeListController()
        list.filter = FileExplorerWindow.listingFilter
        return list
    }()
    /// The entry `r` captured for the pending `rename old -> new` command —
    /// disambiguates the bare old name when the tree has duplicates.
    private var pendingRenamePath: String?
    var currentDirectory: String = ""

    override func update() {
        clear()

        drawHeader(" File explorer ", fg: Theme.fgDark)

        drawTreeListRows(list: list, contentTop: 1, rowCells: explorerRowCells(_:isSelected:))
    }

    /// One tree row's cells — the shared node pipeline
    /// (`Window.fileTreeRowCells`), the explorer's own look verbatim:
    /// tier icons, blue+bold directories, git-marked file names.
    private func explorerRowCells(_ row: FileTree.Row, isSelected: Bool) -> [Cell] {
        guard case .node(let node, let depth) = row else { return [] }
        return Window.fileTreeRowCells(
            node: node,
            depth: depth,
            expanded: list.isExpanded(node),
            selected: isSelected,
            markFg: list.gitMarks[node.path]?.color
        )
    }

    func loadDirectory(_ path: String) {
        currentDirectory = path
        let root = FileTreeNode(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: true)
        // The root is born loaded — its children ARE the listing; the
        // flag is what reveal/rescan walks read on every directory.
        root.listing = ListingFlags(isLoaded: true)
        root.children = loadEntries(at: path)
        list.root = root
        list.resetHorizontalOffset()
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
        guard !currentDirectory.isEmpty, TreePath.isDescendant(path, of: currentDirectory) else { return }
        guard let root = list.root else { return }
        var changed = revealAncestors(root.children, target: path)
        if list.selectFirst(where: { rowNodePath($0) == path }, visibleCount: treeVisibleCount) {
            changed = true
        } else if list.selectedIndex >= list.rows.count {
            list.select(max(0, list.rows.count - 1), visibleCount: treeVisibleCount)
            changed = true
        } else {
            list.ensureVisible(visibleCount: treeVisibleCount)
        }
        // The horizontal counterpart of the vertical ensureVisible
        // above: a revealed deep node is as invisible past the right
        // edge as past the bottom. A moved view counts as a change —
        // reveal must repaint even when the index itself did not move.
        if snapRow(at: list.selectedIndex) {
            changed = true
        }
        if changed {
            dirty = true
        }
    }

    /// Expands every directory along the ancestor chain of `target`,
    /// lazily loading each one's children on the way down.
    @discardableResult
    private func revealAncestors(_ entries: [FileTreeNode], target: String) -> Bool {
        var changed = false
        for node in entries {
            guard node.isDirectory, TreePath.isDescendant(target, of: node.path) else { continue }
            if ensureLoaded(node) { changed = true }
            if list.expand(node) { changed = true }
            if revealAncestors(node.children, target: target) { changed = true }
        }
        return changed
    }

    /// Lazy load: a directory stub's children are read from disk on
    /// its first expand (and by reveal walks). The listing flags were
    /// taken when the stub was created and ride on it, cached until
    /// the directory is rescanned. Mutates the node in place (nodes
    /// are classes — no copy-and-write-back dance).
    @discardableResult
    private func ensureLoaded(_ node: FileTreeNode) -> Bool {
        guard node.isDirectory, node.listing?.isLoaded != true else { return false }
        node.children = loadEntries(at: node.path, parentIgnored: node.listing?.isIgnored ?? false)
        if node.listing == nil { node.listing = ListingFlags() }
        node.listing?.isLoaded = true
        list.invalidate()
        return true
    }

    private func loadEntries(at path: String, parentIgnored: Bool = false) -> [FileTreeNode] {
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
        var dirs = [FileTreeNode]()
        var files = [FileTreeNode]()
        for name in sorted {
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let entry = FileTreeNode(
                name: name,
                path: fullPath,
                isDirectory: isDir.boolValue,
                listing: ListingFlags(
                    isLoaded: false,
                    isIgnored: parentIgnored || ignored.contains(name),
                    isHidden: name.hasPrefix("."))
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

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            if list.move(1, visibleCount: treeVisibleCount) { dirty = true }
        case .char("k"), .up:
            if list.move(-1, visibleCount: treeVisibleCount) { dirty = true }
        case .right:
            if shift(list.horizontalStep) { dirty = true }
        case .left:
            if shift(-list.horizontalStep) { dirty = true }
        case .enter: activateCurrent()
        case .char("l"), .ctrlRight, .ctrl("l"): selectCurrent()
        case .char("h"), .ctrlLeft, .ctrl("h"): collapseCurrent()
        case .char("G"):
            if list.jumpToLast(visibleCount: treeVisibleCount) { dirty = true }
        case .char("g"):
            if list.jumpToFirst(visibleCount: treeVisibleCount) { dirty = true }
        case .char("a"): beginCreate()
        case .char("d"): beginDelete()
        case .char("r"): beginRename()
        case .char("H"): toggleShowAll()
        default: return false
        }
        return true
    }

    /// Left/Right: the shared horizontal shift, clamped by the widest
    /// visible row (the row builder is the single width authority).
    private func shift(_ delta: Int) -> Bool {
        list.shiftHorizontally(
            delta, width: width, visibleCount: treeVisibleCount,
            rowWidth: { explorerRowCells($0, isSelected: false).count })
    }

    /// The rule-B view snaps after an interaction anchored at a branch
    /// (the shared controller's TreeScroll math — minimum movement
    /// into full visibility, none when already visible).
    private func snapToggle(at index: Int) -> Bool {
        list.snapToggle(
            at: index, width: width, visibleCount: treeVisibleCount,
            rowWidth: { explorerRowCells($0, isSelected: false).count })
    }

    private func snapChildren(of index: Int) -> Bool {
        list.snapToChildren(
            ofRow: index, width: width, visibleCount: treeVisibleCount,
            rowWidth: { explorerRowCells($0, isSelected: false).count })
    }

    private func snapRow(at index: Int) -> Bool {
        list.snapToRow(
            index, width: width, visibleCount: treeVisibleCount,
            rowWidth: { explorerRowCells($0, isSelected: false).count })
    }

    /// Enter: opens a file; toggles a directory — collapsed expands and
    /// selection descends, expanded collapses and selection stays.
    /// The branch mechanics (toggle, first-child descend) are the
    /// shared controller's; what a FILE row means — open it — is this
    /// window's policy.
    private func activateCurrent() {
        guard let row = list.selectedRow else { return }
        switch row {
        case .node(let node, _) where node.isDirectory:
            let branchIndex = list.selectedIndex
            ensureLoaded(node)
            list.toggle(node)
            list.descendToFirstChild(visibleCount: treeVisibleCount)
            _ = snapToggle(at: branchIndex)
            dirty = true
        case .node(let node, _):
            delegate?.openFile(node.path)
        case .match:
            break // the explorer's tree carries no match rows
        }
    }

    /// `l` / Ctrl+Right: opens a file; expands a collapsed directory or
    /// descends into an already expanded one — never collapses.
    private func selectCurrent() {
        guard let row = list.selectedRow else { return }
        switch row {
        case .node(let node, _) where node.isDirectory:
            let branchIndex = list.selectedIndex
            ensureLoaded(node)
            list.expand(node)
            list.descendToFirstChild(visibleCount: treeVisibleCount)
            _ = snapChildren(of: branchIndex)
            dirty = true
        case .node(let node, _):
            delegate?.openFile(node.path)
        case .match:
            break
        }
    }

    /// The `h` collapse — the shared policy (`TreeListController` /
    /// `TreeListNavigation`): the key acts on the selected row's parent
    /// branch (the row itself at the top level), selects it and
    /// collapses it when expanded. The collapse wipes the subtree's
    /// expansion memory — re-expanding opens the node fresh. The view
    /// snaps to the target row — collapsing a deep subtree must not
    /// leave the offset parked past the shrunken rows' ends.
    private func collapseCurrent() {
        guard list.selectedRow != nil else { return }
        list.collapseUp(visibleCount: treeVisibleCount)
        _ = snapRow(at: list.selectedIndex)
        dirty = true
    }

    /// `H` — flips the listing filter and re-flattens the tree in memory:
    /// hidden (dot-prefixed) and git-ignored entries stay in the model
    /// with their flags, so no rescan or subprocess happens — the flat
    /// list just includes/excludes the flagged rows. The selection stays
    /// on the same entry when it survives the re-filter, else clamps.
    /// The controller's filter IS the state (nil = show everything);
    /// there is no mirror flag — the initial install happens once, in
    /// the controller's initializer, so the first frame is already
    /// filtered and the first `H` already shows everything.
    private func toggleShowAll() {
        let selectedPath = list.selectedRow.flatMap(rowNodePath)
        // The filter value is REPLACED, not read through captured
        // window state (the controller's no-cycle contract): the
        // filter is a self-contained static function over its node.
        if list.filter == nil {
            list.filter = Self.listingFilter   // was showing everything → hide flagged entries
        } else {
            list.filter = nil                  // was hiding → show everything
        }
        restoreSelection(toPath: selectedPath)
        // A re-filtered list can lose its widest rows — the view snaps
        // to the restored row instead of parking past their ends.
        _ = snapRow(at: list.selectedIndex)
        dirty = true
    }

    /// The `H`-off filter: a flagged listing hides its node — and the
    /// flatten skips the whole subtree (FileTree's filter contract).
    private static func listingFilter(_ node: FileTreeNode) -> Bool {
        guard let listing = node.listing else { return true }
        return !(listing.isHidden || listing.isIgnored)
    }

    /// Restores the selection across a flat-list rebuild: the same path
    /// stays selected when it survives the rebuild, else the index clamps
    /// onto the last row.
    private func restoreSelection(toPath path: String?) {
        if let path, list.selectFirst(where: { rowNodePath($0) == path }, visibleCount: treeVisibleCount) {
            return
        }
        if list.rows.isEmpty {
            list.select(0, visibleCount: treeVisibleCount)
        } else {
            list.select(list.rows.count - 1, visibleCount: treeVisibleCount)
        }
    }

    private func rowNodePath(_ row: FileTree.Row) -> String? {
        guard case .node(let node, _) = row else { return nil }
        return node.path
    }

    /// Content rows below the header — the geometry handed to the
    /// shared list controller.
    private var treeVisibleCount: Int { max(0, height - 1) }

    // MARK: - Create/delete file entries (`a` / `d` → :create / :delete)

    /// The selected node (match rows do not exist in this tree).
    private func selectedNode() -> FileTreeNode? {
        guard case .node(let node, _)? = list.selectedRow else { return nil }
        return node
    }

    /// Relative path of an absolute tree path (nil outside the root) —
    /// the check, the cut and the split are one convention
    /// (`TreePath.remainder`).
    private func relativePath(of absolute: String) -> String? {
        guard let parts = TreePath.remainder(of: absolute, under: currentDirectory) else { return nil }
        return parts.joined(separator: "/")
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
        guard let entry = selectedNode() else { return "./" }
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
        guard let entry = selectedNode() else {
            delegate?.reportError("delete: nothing selected")
            return
        }
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
        guard let entry = selectedNode() else {
            delegate?.reportError("rename: nothing selected")
            return
        }
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
        // A new file is untracked git state — refresh the git-driven
        // decorations (tree marks, editor gutter).
        delegate?.gitWorktreeChanged()
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
        // A shrunk list clamps the stale selection onto a real row, and
        // the view snaps to it — deleting the widest row must not leave
        // the offset parked past the end.
        list.select(list.selectedIndex, visibleCount: treeVisibleCount)
        _ = snapRow(at: list.selectedIndex)
        // A deleted file leaves git state — refresh the decorations.
        delegate?.gitWorktreeChanged()
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
        // A rename is delete+add as far as git is concerned.
        delegate?.gitWorktreeChanged()
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
        let selectedPath = selectedNode()?.path
        reloadPreservingExpansion()
        restoreSelection(toPath: selectedPath)
        _ = snapRow(at: list.selectedIndex)
    }

    /// Rescans the tree from disk while keeping the expansion state of
    /// directories that still exist (`loadDirectory` would collapse
    /// everything). The expansion keys live in the shared controller —
    /// they survive the rescan by construction; this walk only reloads
    /// the children of still-expanded directories, top-down.
    private func reloadPreservingExpansion() {
        let root = FileTreeNode(
            name: (currentDirectory as NSString).lastPathComponent,
            path: currentDirectory,
            isDirectory: true)
        root.listing = ListingFlags(isLoaded: true)
        root.children = reloadChildren(of: root, parentIgnored: false)
        list.root = root
        dirty = true
    }

    /// One rescan level: the directory's entries, and — for children
    /// still expanded — their (recursively rescanned) children.
    private func reloadChildren(of dir: FileTreeNode, parentIgnored: Bool) -> [FileTreeNode] {
        loadEntries(at: dir.path, parentIgnored: parentIgnored).map { entry in
            if entry.isDirectory, list.isExpanded(entry) {
                entry.listing?.isLoaded = true
                entry.children = reloadChildren(of: entry, parentIgnored: entry.listing?.isIgnored ?? false)
            }
            return entry
        }
    }
}

extension FileExplorerWindow: TreeListWindow {
    var treeList: TreeListController { list }
}
