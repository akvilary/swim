import Foundation

class Space {
    let id: String
    private(set) var windows: [String: Window] = [:]
    var focused: Window!
    var prevFocused: Window!

    init(id: String) {
        self.id = id
    }

    func addWindow(_ name: String, _ window: Window) {
        windows[name] = window
    }

    var visibleWindows: [Window] {
        windows.values.filter { $0.visible }
    }

    func markDirty() {
        for window in windows.values {
            window.dirty = true
        }
    }

    func updateFocusStates() {
        for window in windows.values {
            window.focused = (window === focused) && window.visible
        }
    }

    func update() {
        for window in windows.values {
            window.poll()
            if window.visible {
                window.update()
            }
        }
    }

    func focusable() -> [Window] {
        visibleWindows.filter { !($0 is StatusBarWindow) }
    }
}

class Spaces {
    private(set) var all: [String: Space] = [:]
    private(set) var current: Space!

    subscript(_ name: String) -> Space? {
        all[name]
    }

    func addSpace(_ space: Space) {
        all[space.id] = space
    }

    func switchTo(_ spaceId: String) {
        current = all[spaceId]
    }

    func markAllDirty() {
        var seen = Set<ObjectIdentifier>()
        for space in all.values {
            for window in space.windows.values {
                let id = ObjectIdentifier(window)
                if !seen.contains(id) {
                    seen.insert(id)
                    window.dirty = true
                }
            }
        }
        current.updateFocusStates()
    }
}
