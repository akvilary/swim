import Foundation

class Windows {
    let editor = EditorWindow()
    let statusBar = StatusBarWindow()
    let fileExplorer = FileExplorerWindow()
    let gitPanel = GitPanelWindow()
    let searchResults = SearchResultsWindow()
    let preview = PreviewWindow()
    let command = CommandWindow()

    var all: [Window] {
        [editor, statusBar, fileExplorer, gitPanel, searchResults, preview, command]
    }

    var focused: Window!
    var prevFocused: Window!

    func assignDelegates(_ delegate: WindowDelegate) {
        editor.delegate = delegate
        fileExplorer.delegate = delegate
        gitPanel.delegate = delegate
        searchResults.delegate = delegate
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
