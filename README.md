# Swim

A Vim-like terminal text editor written in pure Swift with zero external dependencies. Works on macOS and Linux.

![Theme: Tokyo Night Storm](https://img.shields.io/badge/theme-Tokyo%20Night%20Storm-blueviolet)

## Features

- **Modal editing** — Normal, Insert, Visual, and Command modes with familiar Vim keybindings (`h/j/k/l`, `dd`, `yy`, `p`, `i`, `v`, `:`, `/`, etc.)
- **Piece Table** — efficient text data structure (same as VS Code)
- **Syntax highlighting** — three levels:
  - Semantic tokens via LSP (sourcekit-lsp)
  - Built-in tokenizer for Swift, C, C++, Python, Rust, Go, JS/TS
  - Fast JSON highlighting
- **File explorer** (`Ctrl+E`) — sidebar with directory tree
- **Git panel** (`Ctrl+G`) — staged/unstaged files, commits, diff with color highlighting
- **Project search** (`Ctrl+F`) — recursive file search with grouped results
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
| `Esc` | Any | Return to Normal mode |
| `v` | Normal | Enter Visual mode |
| `:` | Normal | Command line |
| `/` | Normal | Search |
| `h/j/k/l` | Normal | Navigation |
| `dd` | Normal | Delete line |
| `yy` | Normal | Yank line |
| `p` | Normal | Paste |
| `Ctrl+E` | Normal | File explorer |
| `Ctrl+G` | Normal | Git panel |
| `Ctrl+F` | Normal | Project search |

### Commands

- `:w` — save
- `:q` — quit
- `:wq` — save and quit
- `:q!` — force quit
- `:e <path>` — open file
- `:%s/old/new/g` — substitute

## Project structure

```
Sources/Swim/
├── main.swift              # Entry point
├── App/
│   └── Application.swift   # Main event loop, rendering, LSP
├── Core/
│   ├── Cell.swift           # Screen cells, colors
│   ├── Theme.swift          # Tokyo Night Storm palette
│   ├── Terminal.swift       # Low-level terminal I/O
│   ├── PieceTable.swift     # Text buffer
│   ├── Input.swift          # Key parsing
│   └── SyntaxTokenizer.swift # Built-in highlighting
├── Window/
│   ├── EditorWindow.swift       # Editor with modes
│   ├── FileExplorerWindow.swift  # File explorer
│   ├── GitPanelWindow.swift      # Git panel
│   ├── SearchWindow.swift        # Search
│   └── StatusBarWindow.swift     # Status bar
└── LSP/
    ├── LSPClient.swift      # sourcekit-lsp client
    └── LSPProtocol.swift    # LSP data types
```

## License

MIT
