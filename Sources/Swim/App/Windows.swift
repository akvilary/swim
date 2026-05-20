import Foundation

class Windows {
    let editor = EditorWindow()
    let statusBar = StatusBarWindow()
    let fileExplorer = FileExplorerWindow()
    let gitPanel = GitPanelWindow()
    let search = SearchWindow()
    let command = CommandWindow()

    var all: [Window] {
        [editor, statusBar, fileExplorer, gitPanel, search, command]
    }

    var focused: Window!
    var prevFocused: Window!

    func assignDelegates(_ delegate: WindowDelegate) {
        editor.delegate = delegate
        fileExplorer.delegate = delegate
        gitPanel.delegate = delegate
        search.delegate = delegate
        command.delegate = delegate
    }

    func updateFocusStates() {
        for window in all {
            window.focused = (window === focused) && window.visible
        }
    }

    func markAllDirty() {
        for window in all {
            window.dirty = true
        }
        updateFocusStates()
    }

    func updateAll() {
        for window in all {
            if window.visible {
                window.update()
            }
        }
    }

    func focusable() -> [Window] {
        all.filter { $0.visible && !($0 is StatusBarWindow) }
    }
}
