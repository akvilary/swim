# Swim

A Vim-like terminal text editor written in pure Swift with zero external dependencies. Works on macOS and Linux.

![Theme: Tokyo Night Storm](https://img.shields.io/badge/theme-Tokyo%20Night%20Storm-blueviolet)

## Features

- **Modal editing** — Normal, Insert, Visual, and Command modes with familiar Vim keybindings (`h/j/k/l`, `dd`, `yy`, `p`, `i`, `v`, `:`, `/`, etc.); `:` opens the command line from any window (typed via the status bar)
- **Window stack** — focusing a window raises it to the top of the stack; `:q` / `Ctrl+X` / `Esc` close the focused window (an editor tab or a panel), falling back to the window beneath; closing the last window exits
- **Piece Table** — efficient text data structure (same as VS Code)
- **Syntax highlighting** — three levels:
  - Semantic tokens via LSP (sourcekit-lsp)
  - Built-in tokenizer for Swift, C, C++, Python, Rust, Go, JS/TS
  - Fast JSON highlighting
- **File explorer** (`Ctrl+E`) — sidebar with directory tree
- **Git panel** (`Ctrl+G`) — staged/unstaged files, commits, diff with color highlighting
- **Project search** (`Ctrl+F`) — recursive file search with grouped results
- **Built-in terminal** (`Ctrl+T`) — run shell commands inside the editor: the prompt is the last line of the scrollback, arrows scroll the output, `Ctrl+Left/Right` recalls commands, `Tab` completes paths; `cd` and `clear` are handled by the window itself
- **Full UTF-8 support** — Cyrillic, CJK, emoji
- **Tokyo Night Storm theme**
- **Status bar** — mode, filename, file type, encoding, cursor position

## Install

**macOS (Homebrew):**

```bash
brew install akvilary/swim/swim
```

**macOS / Linux (curl):**

```bash
curl -fsSL https://raw.githubusercontent.com/akvilary/swim/main/install.sh | bash
```

Specify a version:

```bash
curl -fsSL https://raw.githubusercontent.com/akvilary/swim/main/install.sh | bash -s v0.0.1
```

Custom install path:

```bash
curl -fsSL https://raw.githubusercontent.com/akvilary/swim/main/install.sh | DESTDIR=~/.local/bin bash
```

**Build from source** (requires Swift 6.0+):

```bash
git clone https://github.com/akvilary/swim.git
cd swim
swift build -c release
cp .build/release/Swim /usr/local/bin/swim
```

## Usage

```bash
swim              # Open empty buffer
swim <file>       # Open file
```

### Key bindings

| Key | Mode | Action |
|---|---|---|
| `i` | Normal | Enter Insert mode |
| `Esc` | Any | Return to Normal mode / close focused panel |
| `v` | Normal | Enter Visual mode |
| `:` | Any (not Insert) | Command line (via status bar) |
| `/` | Normal | Search |
| `h/j/k/l` | Normal | Navigation |
| `dd` | Normal | Delete line |
| `yy` | Normal | Yank line |
| `p` | Normal | Paste |
| `Ctrl+E` | Any | File explorer |
| `Ctrl+G` | Any | Git panel |
| `Ctrl+F` | Any | Project search |
| `Ctrl+T` | Any | Built-in terminal |
| `Ctrl+X` | Any | Close focused window (last window exits) |
| `Tab` | Normal | Cycle focus (in window-stack order) |

### Commands

- `:w` — save
- `:q` — close focused window (editor tab or panel; refuses unsaved changes)
- `:wq` — save and close the editor tab
- `:q!` — force close
- `:qa` — quit the app
- `:e <path>` — open file (reveals a hidden editor)
- `:terminal` / `:term` / `:sh` — open the built-in terminal
- `:%s/old/new/g` — substitute

## Project structure

```
Sources/Swim/
├── main.swift              # Entry point
├── App/
│   ├── Application.swift   # Main event loop, window stack, focus, LSP
│   ├── Spaces.swift        # Window spaces (editor, search)
│   ├── LayoutManager.swift # Window rectangle layout
│   ├── Renderer.swift      # Diff-based terminal rendering
│   └── WindowDelegate.swift # Window → Application events
├── Core/
│   ├── Cell.swift           # Screen cells, colors
│   ├── Theme.swift          # Tokyo Night Storm palette
│   ├── Terminal.swift       # Low-level terminal I/O
│   ├── PieceTable.swift     # Text buffer
│   ├── EditorBuffer.swift   # Buffer state + tab manager
│   ├── Input.swift          # Key parsing
│   ├── SyntaxTokenizer.swift # Built-in highlighting
│   ├── Shell.swift          # Subprocess runner (git, which)
│   └── BackgroundTask.swift # Background job with thread-safe result
├── Window/
│   ├── EditorWindow.swift       # Editor with modes
│   ├── TabBarWindow.swift       # Tab bar above the editor
│   ├── FileExplorerWindow.swift # File explorer
│   ├── GitPanelWindow.swift     # Git panel
│   ├── SearchResultsWindow.swift # Project search
│   ├── PreviewWindow.swift      # File preview (search space)
│   ├── CommandWindow.swift      # Long git command output (pull/push)
│   ├── TerminalWindow.swift     # Built-in terminal
│   └── StatusBarWindow.swift    # Status bar
└── LSP/
    ├── LSPClient.swift      # sourcekit-lsp client
    └── LSPProtocol.swift    # LSP data types
```

## License

MIT
