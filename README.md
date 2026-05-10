# Swim

Текстовый редактор для терминала в стиле Vim, написанный на чистом Swift без внешних зависимостей. Работает на macOS и Linux.

![Theme: Tokyo Night Storm](https://img.shields.io/badge/theme-Tokyo%20Night%20Storm-blueviolet)

## Возможности

- **Модальное редактирование** — режимы Normal, Insert, Visual и Command с привычными хоткеями (`h/j/k/l`, `dd`, `yy`, `p`, `i`, `v`, `:`, `/` и т.д.)
- **Piece Table** — структура данных для эффективной работы с текстом (как в VS Code)
- **Подсветка синтаксиса** — три уровня:
  - Семантические токены через LSP (sourcekit-lsp)
  - Встроенный токенизатор для Swift, C, Python, Rust, Go, JS/TS
  - Быстрая подсветка JSON
- **Проводник файлов** (`Ctrl+E`) — боковая панель с деревом директорий
- **Git-панель** (`Ctrl+G`) — staged/unstaged файлы, коммиты, diff с цветовой подсветкой
- **Поиск по проекту** (`Ctrl+F`) — рекурсивный поиск по файлам с группировкой результатов
- **Полная поддержка UTF-8** — кириллица, CJK, эмодзи
- **Тема Tokyo Night Storm**
- **Строка состояния** — режим, имя файла, тип, кодировка, позиция курсора

## Установка

### Требования

- Swift 6.0+
- macOS 13+ или Linux

### Сборка и установка

```bash
git clone https://github.com/akvilary/swim.git
cd swim
./build.sh
```

Скрипт `build.sh` скомпилирует release-бинарник и скопирует его в `~/.local/bin/swim`. Убедитесь, что `~/.local/bin` есть в `$PATH`.

### Ручная сборка

```bash
swift build -c release
cp .build/release/Swim ~/.local/bin/swim
```

## Использование

```bash
swim              # Новый пустой файл
swim <файл>       # Открыть файл
```

### Основные комбинации клавиш

| Клавиша | Режим | Действие |
|---|---|---|
| `i` | Normal | Войти в Insert |
| `Esc` | Любой | Вернуться в Normal |
| `v` | Normal | Войти в Visual |
| `:` | Normal | Командная строка |
| `/` | Normal | Поиск |
| `h/j/k/l` | Normal | Навигация |
| `dd` | Normal | Удалить строку |
| `yy` | Normal | Копировать строку |
| `p` | Normal | Вставить |
| `Ctrl+E` | Normal | Проводник файлов |
| `Ctrl+G` | Normal | Git-панель |
| `Ctrl+F` | Normal | Поиск по проекту |

### Команды

- `:w` — сохранить
- `:q` — выйти
- `:wq` — сохранить и выйти
- `:q!` — выйти без сохранения
- `:e <путь>` — открыть файл
- `:%s/старое/новое/g` — замена

## Структура проекта

```
Sources/Swim/
├── main.swift              # Точка входа
├── App/
│   └── Application.swift   # Главный цикл событий, рендеринг, LSP
├── Core/
│   ├── Cell.swift           # Ячейки экрана, цвета
│   ├── Theme.swift          # Палитра Tokyo Night Storm
│   ├── Terminal.swift       # Низкоуровневый I/O терминала
│   ├── PieceTable.swift     # Буфер текста
│   ├── Input.swift          # Парсинг клавиш
│   └── SyntaxTokenizer.swift # Встроенная подсветка
├── Window/
│   ├── EditorWindow.swift       # Редактор с модами
│   ├── FileExplorerWindow.swift  # Проводник файлов
│   ├── GitPanelWindow.swift      # Git-панель
│   ├── SearchWindow.swift        # Поиск
│   └── StatusBarWindow.swift     # Строка состояния
└── LSP/
    ├── LSPClient.swift      # Клиент sourcekit-lsp
    └── LSPProtocol.swift    # Типы данных LSP
```

## Лицензия

MIT
