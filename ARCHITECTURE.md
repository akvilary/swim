# Swim — Терминальный текстовый редактор на Swift

## Обзор

Swim — это vim-подобный терминальный текстовый редактор, написанный на чистом Swift без внешних зависимостей. Работает на Linux и macOS. Использует тему Tokyo Night Storm, структуру данных Piece Table, встроенный файловый проводник, git-панель, поиск по проекту и LSP семантическую подсветку.

---

## Архитектура

```
main.swift
  └── Application (оркестратор)
        ├── Terminal.shared (низкоуровневый I/O)
        ├── Key.parse() (парсинг ввода)
        ├── EditorWindow (основной редактор)
        │     ├── PieceTable (текстовый буфер)
        │     ├── SyntaxTokenizer (fallback-подсветка)
        │     └── SemanticToken[] (LSP-подсветка)
        ├── FileExplorerWindow (файловое дерево)
        ├── GitPanelWindow (git status/commits/diff)
        ├── SearchWindow (поиск по проекту)
        ├── StatusBarWindow (режим/позиция)
        └── LSPClient (семантические токены через sourcekit-lsp)
```

### Потоки данных

**Ввод:** `Terminal.readByte()` → `Key.parse()` → `Application.handleGlobalKey()` → `Window.handleKey()`

**Редактирование:** `EditorWindow.handleKey()` → `PieceTable.insert/delete` → буфер изменён → `dirty = true`

**Рендеринг:** `Window.update()` заполняет cell-буфер → `Application.render()` сравнивает с предыдущим кадром → `Terminal` отправляет ANSI-escape → `flush()` в stdout

**Подсветка синтаксиса:** `LSPClient` получает токены от sourcekit-lsp ИЛИ `SyntaxTokenizer` генерирует их → `EditorWindow.semanticTokens` → маппинг на цвета через `Theme`

**Межоконная коммуникация:** `Application` связывает замыкания (`onFileSelect`, `onResultSelect`, `onCommand`) между окнами

---

## Структура файлов

```
Sources/Swim/
├── main.swift                    — Точка входа
├── App/
│   └── Application.swift         — Главный контроллер
├── Core/
│   ├── Cell.swift                — Ячейка экрана + цвет
│   ├── Theme.swift               — Палитра Tokyo Night Storm
│   ├── Terminal.swift            — Низкоуровневый терминальный I/O
│   ├── PieceTable.swift          — Структура данных текстового буфера
│   ├── Input.swift               — Парсинг клавиш
│   └── SyntaxTokenizer.swift     — Встроенная подсветка синтаксиса
├── Window/
│   ├── Window.swift              — Базовый класс окна (cell-буфер)
│   ├── EditorWindow.swift        — Vim-редактор
│   ├── FileExplorerWindow.swift  — Файловый проводник
│   ├── GitPanelWindow.swift      — Git-панель
│   ├── SearchWindow.swift        — Поиск по проекту
│   └── StatusBarWindow.swift     — Строка состояния
└── LSP/
    ├── LSPClient.swift           — Клиент Language Server Protocol
    └── LSPProtocol.swift         — Типы данных LSP
```

---

## Детальное описание модулей

### Core/Cell.swift — Ячейка экрана

**`Color`** (enum) — цвет терминала. Поддерживает 16 стандартных ANSI-цветов + 24-bit RGB через `Color.rgb(r:g:b:)`. Имеет вычисляемые свойства `ansiFG` и `ansiBG` — ANSI-escape последовательности для установки цвета текста и фона.

**`Cell`** (struct, Equatable) — одна ячейка экрана. Содержит:
- `char: Character` — отображаемый символ
- `fg/bg: Color` — цвета текста и фона
- `bold/dim/underline/reverse: Bool` — текстовые атрибуты
- `wideContinuation: Bool` — true если ячейка — правая половина широкого символа (CJK/emoji)

Фабричный метод `Cell.colored(_:fg:bg:bold:dim:underline:reverse:)` создаёт ячейку с заданными параметрами.

---

### Core/Theme.swift — Цветовая палитра

Безэкземплярный enum `Theme` — пространство имён для статических цветов Tokyo Night Storm:

| Свойство    | HEX       | Назначение              |
|-------------|-----------|-------------------------|
| `bg`        | `#24283b` | Основной фон            |
| `bgDark`    | `#1f2335` | Фон боковых панелей     |
| `bgHighlight` | `#292e42` | Фон выделения         |
| `fg`        | `#c0caf5` | Основной текст          |
| `fgDark`    | `#a9b1d6` | Вторичный текст         |
| `comment`   | `#565f89` | Комментарии             |
| `blue`      | `#7aa2f7` | Функции                 |
| `blue1`     | `#2ac3de` | Типы                    |
| `blue5`     | `#89ddff` | Операторы               |
| `green`     | `#9ece6a` | Строки                  |
| `magenta`   | `#bb9af7` | Ключевые слова          |
| `orange`    | `#ff9e64` | Числа/параметры         |

---

### Core/Terminal.swift — Терминальный I/O

Синглтон `Terminal.shared` с `nonisolated(unsafe)` для Swift 6.

**Настройка (`setup()`):**
1. Сохраняет текущие настройки termios
2. Переключает терминал в raw-режим (отключает echo, канонический режим, обработку сигналов)
3. Получает размер терминала через `ioctl(TIOCGWINSZ)`
4. Переключает на альтернативный экранный буфер (`\e[?1049h`)
5. Скрывает курсор (`\e[?25l`)
6. Устанавливает обработчик SIGWINCH (для отслеживания изменения размера)

**Восстановление (`restore()`):** Возвращает оригинальные настройки termios, переключает обратно на основной буфер, показывает курсор.

**Ввод:**
- `readByte() -> UInt8?` — читает один байт из stdin (блокирующий)
- `bytesAvailable() -> Bool` — проверяет наличие данных через `poll()` с таймаутом 5мс

**Вывод (буферизованный):**
- `moveCursor(row:col:)`, `setFG()`, `setBG()`, `setBold()`, `setDim()`, `setUnderline()`, `setReverse()`, `resetAttributes()`, `writeChar()` — добавляют ANSI-escape последовательности в `outputBuffer`
- `flush()` — записывает весь буфер в stdout одной системным вызовом через `write(STDOUT_FILENO, ...)`, затем очищает буфер

Все записи в терминал идут через `write(STDOUT_FILENO, ...)` напрямую, минуя stdio буферизацию.

---

### Core/PieceTable.swift — Текстовый буфер

Piece Table — структура данных для текстовых редакторов (используется в VS Code). Идеальна для частых вставок/удалений: исходный буфер неизменяем, все добавления аппендятся в отдельный буфер.

**Принцип работы:**

Два байтовых буфера:
- `original: [UInt8]` — исходное содержимое файла (никогда не изменяется)
- `addBuffer: [UInt8]` — append-only буфер для всех вставок

Массив `pieces: [Piece]` — упорядоченный список дескрипторов, каждый из которых ссылается на диапазон байт в одном из буферов. Документ — это конкатенация всех pieces.

**Пример:**
```
original: "Hello World"
addBuffer: ", beautiful"
pieces: [
    Piece(start: 0, length: 5, isAdd: false),   // "Hello"
    Piece(start: 0, length: 11, isAdd: true),    // ", beautiful"
    Piece(start: 5, length: 6, isAdd: false),    // " World"
]
→ Результат: "Hello, beautiful World"
```

**Индекс строк (`lineStarts: [Int]`):**
Массив байтовых смещений начала каждой строки. Построение:
1. При инициализации — полный скан всех байт через `withUnsafeBufferPointer` + `reserveCapacity` (оптимизация для больших файлов)
2. При вставке/удалении — перестройка только от точки изменения (`rebuildLineIndex(fromOffset:)`)
3. Поиск строки по байтовому смещению — бинарный поиск O(log n)

**Кеш строки:**
`cachedLineNum` / `cachedLineStr` — кеш последней декодированной строки. `getLine()` проверяет кеш перед созданием новой String. Инвалидируется при insert/delete. Это критически важно: одна строка может вызываться через `getLine()`, `lineCharLength()`, `charToByteOffsetInLine()` в одном кадре.

**UTF-8 поддержка:**
Внутреннее хранение — байты. Курсор работает в символьных позициях. Конвертация:
- `charToByteOffsetInLine(line:charIndex:)` — символьный индекс → байтовое смещение
- `byteToCharOffsetInLine(line:byteOffset:)` — байтовое смещение → символьный индекс
- `lineCharLength(line:)` — длина строки в символах (не байтах)

**Ключевые операции:**
- `insert(_:at:)` — O(1) append в addBuffer + O(pieces) для вставки Piece + O(n) перестройка индекса от точки вставки
- `delete(at:length:)` — O(pieces) для модификации/удаления Pieces + O(n) перестройка индекса
- `getLine(_:)` — O(1) lookup в lineStarts + O(piece) для сборки байт + декодирование UTF-8
- `search(_:from:)` — O(n) побайтовый поиск с backtracking

---

### Core/Input.swift — Парсинг ввода

**`Key`** (enum) — представляет нажатие клавиши:
- `.char(Character)` — печатный символ
- `.escape` — Escape
- `.enter` / `.backspace` / `.delete` / `.tab`
- `.up` / `.down` / `.left` / `.right` — стрелки
- `.home` / `.end` / `.pageUp` / `.pageDown`
- `.ctrl(Character)` — Ctrl+буква (байты 1-26)
- `.f(Int)` — F1-F12
- `.shiftTab` — Shift+Tab
- `.unknown(String)` — нераспознанная последовательность

**`Key.parse(from:)`** — читает байты из терминала и распознаёт:
- Одиночные байты (печатные, Ctrl-комбинации)
- CSI-последовательности (`\e[...`) — стрелки, Home/End, Page Up/Down, Delete
- SS3-последовательности (`\eO...`) — альтернативные коды F1-F4
- Shift-модификаторы (`\e[1;2...`) — Shift+Arrow, Shift+Tab
- Ctrl-стрелки (`\e[1;5...`)
- Многобайтные UTF-8 символы

---

### Core/SyntaxTokenizer.swift — Встроенная подсветка

Линейный токенизатор для 6 языков: Swift, C, Python, Rust, Go, JavaScript/TypeScript.

**`SyntaxToken`** — токен с полями `line`, `startChar`, `length`, `type`, `modifiers`.

**`tokenize(line:lineNum:keywords:)`** — парсит одну строку:
- `//` — однострочный комментарий
- `/* */` — блочный комментарий (в пределах строки)
- `"..."` / `'...'` — строки с поддержкой escape-символов
- Числа (включая hex-цифры)
- Идентификаторы → классифицируются как keyword/type/function/variable
- Операторы (`+-*/=<>!&|^~%?:@#`)

Для файлов >50K строк встроенная подсветка отключается (флаг `useBuiltinTokens`).

Для JSON-файлов используется отдельный быстрый рендеринг без токенов — посимвольная раскраска прямо в `EditorWindow.update()`:
- Строки в кавычках → зелёный (`Theme.green`)
- `{`, `}`, `[`, `]`, `,`, `:` → белый (`Theme.fg`)
- Всё остальное → оранжевый (`Theme.orange`)

---

### Window/Window.swift — Базовый класс окна

Абстрактный базовый класс для всех UI-панелей. Реализует виртуальный cell-буфер.

**Cell-буфер:** Плоский массив `[Cell]` размером `width * height`. Индекс ячейки = `row * width + col`.

**Ключевые методы:**
- `setCell(_:_:_:)` — устанавливает ячейку с bounds-проверкой. Устанавливает `dirty = true` при изменении
- `getCell(_:_:)` — возвращает ячейку (`.blank` при выходе за границы)
- `fillRegion(row:col:width:height:cell:)` — заливает прямоугольную область
- `writeString(_:row:col:fg:bg:bold:)` — записывает строку в буфер с обработкой табов (4 пробела)
- `handleKey(_:) -> Bool` — точка переопределения для обработки клавиш
- `update()` — точка переопределения для обновления cell-буфера

**Dirty-флаг:** `dirty = true` означает что cell-буфер изменился и нужно перерисовать окно. Проверяется в `Application.render()`.

---

### Window/EditorWindow.swift — Основной редактор

Центральный компонент — vim-подобный модальный редактор.

**Режимы (`EditorMode`):**
- `.normal` — перемещение, команды (h/j/k/l, dd, yy, p, x, i, v, :, /...)
- `.insert` — ввод текста (Escape для выхода)
- `.visual` — визуальное выделение (y — копировать, d — удалить)
- `.command` — командная строка (:w, :q, :wq, :q!, :e path, :%s/old/new/g, /search)

**Система координат:**
- `cursorLine` / `cursorCol` — позиция курсора в символах (не байтах!)
- `scrollY` / `scrollX` — вертикальная/горизонтальная прокрутка в символах
- Конвертация в байты — через `PieceTable.charToByteOffsetInLine()` при insert/delete

**Рендеринг (`update()`):**
1. Заливка фона `Theme.bg`
2. Номера строк в левой колонке (ширина: `max(4, digitCount + 2)`)
3. Для каждой видимой строки:
   - JSON → быстрый посимвольный рендеринг (без токенов)
   - LSP токены доступны → `semanticTokensFor(line:)`
   - Иначе → `SyntaxTokenizer.tokenize()` (только для файлов <50K строк)
4. Подсветка визуального выделения
5. Отрисовка курсора (reverse video в normal, underline в insert)

**Маппинг типов токенов на цвета:**
keyword → magenta, string → green, number → orange, comment → серый, type → blue1, function → blue, variable → fg, operator → blue5

---

### Window/FileExplorerWindow.swift — Файловый проводник

Боковая панель с деревом файлов. Поддерживает разворачивание/сворачивание директорий, выбор файлов, emoji-иконки для типов файлов.

**Структура данных:**
- `FileEntry` — файл/директория (name, path, isDirectory, isExpanded, children, isLoaded)
- `rootEntries: [FileEntry]` — корневые записи
- `flatEntries: [(entry: FileEntry, depth: Int)]` — плоский список видимых записей

**Управление:**
- `j/k` — вверх/вниз
- `Enter/l/right` — выбрать файл / развернуть директорию
- `h/left` — свернуть / перейти к родителю
- `g/G` — прыгнуть в начало/конец

Скрытые файлы (начинающиеся с `.`) фильтруются. Директории сортируются перед файлами.

Emoji-иконки: 🐦 Swift, 🌐 JS, 🐍 Python, 🦀 Rust, 🐹 Go, 📝 Markdown, 📋 JSON, и т.д.

---

### Window/GitPanelWindow.swift — Git-панель

Панель интеграции с Git. Показывает staged/unstaged/untracked файлы, последние коммиты, diff.

**Данные:**
- `GitFileStatus` — статус файла (M/A/D/R/?, filePath, staged)
- `GitCommit` — коммит (hash, author, date, message)

**Управление:**
- `j/k` — навигация
- `Enter` — показать diff для выбранного файла
- `Escape` — закрыть diff

Все git-операции выполняются через `/usr/bin/git` как подпроцесс.

Diff подсвечивается: зелёный для добавлений, красный для удалений, голубой для заголовков блоков.

---

### Window/SearchWindow.swift — Поиск по проекту

Панель поиска с древовидным отображением результатов, сгруппированных по директориям и файлам.

**Поиск (`search(query:in:)`):**
- Рекурсивно обходит все файлы в директории
- Исключает: `.git`, `node_modules`, `.build`, `build`, `DerivedData`
- Пропускает бинарные файлы (png/jpg/zip/exe/o/so/...)
- Построчный case-insensitive поиск

**Структура результатов:**
- `SearchResult` — filePath, lineNumber, lineContent, matchStart, matchLength
- `groupedResults` — сгруппированы по директориям → файлам

**Управление:**
- `j/k` — навигация
- `Enter/l/right` — развернуть/свернуть директорию/файл, перейти к результату
- `h/left` — свернуть

---

### Window/StatusBarWindow.swift — Строка состояния

Однострочная панель внизу экрана:

**Левая часть:** Цветной бейдж режима (NORMAL=синий, INSERT=зелёный, VISUAL=фиолетовый, COMMAND=оранжевый)

**Центр:** В режиме COMMAND — `:<команда>`. Иначе — `[+] filename` (+ если есть несохранённые изменения)

**Правая часть:** Тип файла, кодировка, `строка:столбец`, процент позиции в файле

---

### LSP/LSPClient.swift — LSP-клиент

Клиент Language Server Protocol для семантической подсветки через sourcekit-lsp.

**Протокол:** JSON-RPC 2.0 поверх stdin/stdout с framing `Content-Length: N\r\n\r\n`.

**Жизненный цикл:**
1. `start()` — запускает sourcekit-lsp как подпроцесс через `Process`
2. `sendInitialize()` — отправляет `initialize` с capabilities (semantic tokens full/delta)
3. `handleInitializeResponse()` — извлекает token legend, отправляет `initialized`
4. `openDocument()` — отправляет `textDocument/didOpen` + запрашивает semantic tokens
5. `handleSemanticTokensResponse()` — парсит LSP semtok protocol (кортежи по 5 int: deltaLine, deltaStart, length, tokenType, tokenModifiers) → `[SemanticToken]`
6. `Application.pollLSP()` — периодически проверяет `pendingTokens` и переносит в `EditorWindow`

**Асинхронность:** Чтение из stdout LSP-сервера через `DispatchSourceRead` на отдельной очереди. Запись в stdin — через `queue.async`.

**Ограничение:** Для файлов >5MB LSP не используется (отправка полного текста через `getAllText()` слишком медленная).

---

### LSP/LSPProtocol.swift — Типы данных LSP

Определяет Codable-структуры для LSP протокола:
- `SemanticToken` — разделяемый тип токена (используется и LSPClient, и SyntaxTokenizer)
- Позиции, диапазоны, capabilities, запросы/ответы

LSPClient использует сырые `[String: Any]` словари для JSON вместо Codable-типов для простоты.

---

### App/Application.swift — Главный контроллер

Оркестратор всего приложения. Управляет главным циклом событий, layout окон, глобальными горячими клавишами, LSP и рендерингом.

**Главный цикл (`run()`):**
```
setup terminal
open file / new file
load file explorer from CWD
setup LSP
calculate layout
render initial frame

while running:
    poll LSP tokens
    if input available:
        parse key
        handle global key
        update all windows
        render
```

**Глобальные горячие клавиши:**
- `Ctrl+E` — файловый проводник
- `Ctrl+G` — git-панель
- `Ctrl+F` — поиск
- `Ctrl+C` — выход
- `Tab` (в normal mode) — циклическое переключение фокуса

**Layout (`recalculateLayout()`):**
- Файловый проводник: до 28 колонок или 1/4 ширины, слева
- Редактор: оставшееся пространство справа
- Git-панель / поиск: до 15 строк или 1/3 высоты, снизу
- Строка состояния: 1 строка, самый низ

**Оптимизированный рендеринг (`render()`):**
1. Вызывает `update()` на всех видимых окнах
2. Для каждой ячейки каждого окна:
   - Сравнивает с `prevScreenCells[row][col]` (предыдущий кадр)
   - Если изменилась — отправляет ANSI-escape для перемещения курсора + изменения атрибутов + записи символа
   - Отслеживает текущие атрибуты терминала (`termFG`, `termBG`, `termBold`...) чтобы не отправлять повторные escape-последовательности
3. `terminal.flush()` — одна запись в stdout

Это diff-based рендеринг — перерисовываются только изменённые ячейки, минимизируя I/O в терминал.

---

## Горячие клавиши

### Режим Normal
| Клавиша | Действие |
|---------|----------|
| `h`/`j`/`k`/`l` | Перемещение курсора |
| `w` / `b` | На слово вперёд / назад |
| `0` / `$` | В начало / конец строки |
| `gg` / `G` | В начало / конец файла |
| `i` / `a` / `A` / `I` | Вход в Insert (до/после/конец строки/начало строки) |
| `o` / `O` | Новая строка снизу/сверху + Insert |
| `x` | Удалить символ |
| `dd` | Удалить строку |
| `yy` | Копировать строку |
| `p` / `P` | Вставить после/до курсора |
| `u` | Отмена (stub) |
| `v` | Visual-режим |
| `:` | Command-режим |
| `/` | Поиск вперёд |
| `n` / `N` | Следующий / предыдущий результат поиска |
| `Ctrl+f` / `Ctrl+b` | Page Down / Page Up |

### Глобальные
| Клавиша | Действие |
|---------|----------|
| `Ctrl+E` | Файловый проводник |
| `Ctrl+G` | Git-панель |
| `Ctrl+F` | Поиск по проекту |
| `Ctrl+C` | Выход |
| `Tab` | Переключение фокуса (в Normal) |

### Команды (`:`)
| Команда | Действие |
|---------|----------|
| `:w` | Сохранить |
| `:q` | Выйти (только если нет изменений) |
| `:wq` / `:x` | Сохранить и выйти |
| `:q!` | Выйти принудительно |
| `:e <path>` | Открыть файл |
| `:%s/old/new/g` | Замена в текущей строке |
| `/<query>` | Поиск вперёд |

---

## Оптимизации производительности

1. **Pre-allocation в `rebuildLineIndex()`** — `reserveCapacity` на основе размера файла предотвращает ~22 реаллокации для файлов с миллионами строк

2. **`withUnsafeBufferPointer`** — прямой доступ к памяти буферов при сканировании переносов строк

3. **Кеш строки** — `getLine()` кеширует последнюю декодированную строку, избегая повторного декодирования UTF-8

4. **Diff-based рендеринг** — перерисовываются только изменившиеся ячейки через сравнение с `prevScreenCells`

5. **Отслеживание атрибутов** — ANSI-escape для изменения цвета/стиля отправляется только если атрибут действительно изменился

6. **Пропуск LSP для больших файлов** — файлы >5MB не отправляются в sourcekit-lsp (иначе `getAllText()` создаёт гигантскую строку)

7. **Пропуск подсветки для больших файлов** — встроенный токенизатор отключается для файлов >50K строк

8. **Быстрый JSON-рендеринг** — для `.json` файлов подсветка делается посимвольно прямо при рендеринге, без создания токенов
