# Swim — Отчёт о рефакторинге

## Объём изменений

- **Коммитов:** 2
- **Файлов изменено:** 16 (из них 3 новых)
- **Строк добавлено:** ~920
- **Строк удалено:** ~545
- **Чистый прирост:** ~375 строк (при этом Application.swift сокращён на ~160 строк)

---

## P0 — Критические исправления

### 1.1 Устранён двойной вызов `updateAllWindows()`

**Файл:** `Application.swift`

Каждый кадр все окна обновлялись дважды: один раз в главном цикле `run()`, второй — внутри `render()`. Убран вызов из `render()`, добавлен пропущенный вызов перед первым рендером при старте.

### 1.2 Реализована обработка SIGWINCH (resize терминала)

**Файл:** `Terminal.swift`, `Application.swift`

Обработчик сигнала был пустой — изменение размера терминала игнорировалось. Реализован паттерн **self-pipe**:

- `signalHandler` пишет байт в pipe при SIGWINCH
- `hasResizeEvent` / `consumeResizeEvent()` — неблокирующая проверка через `poll()`
- Event loop в `run()` проверяет resize перед каждым вводом и вызывает `recalculateLayout()` + полный перерисовку
- Pipe корректно закрывается в `restore()`

### 1.3 Исправлена потокобезопасность CommandWindow

**Файл:** `CommandWindow.swift`

Глобальные `nonisolated(unsafe)` переменные `_cmdResult` / `_cmdDone` записывались из фонового потока и читались из главного без синхронизации. Добавлен `NSLock` (`_cmdLock`) — все записи и чтения защищены. `pollResult()` копирует данные под локом и освобождает его перед вызовом callback.

### 1.4 Исправлено определение ширины символов (CJK + Emoji)

**Файл:** `Application.swift` → `Renderer.swift`, `FileExplorerWindow.swift`

Оригинальная проверка `first >= 0xF0` покрывала только 4-байтные UTF-8 (emoji), но пропускала CJK из 3-байтного диапазона (U+4E00–U+9FFF). Моя первая попытка исправить это добавила CJK, но сломала emoji иконки в File Explorer.

Финальная реализация — полная таблица East Asian Wide символов:
- Hangul Jamo (U+1100–U+115F)
- CJK (U+2E80–U+9FFF, U+F900–U+FAFF)
- Emoji Presentation ranges (U+1F000–U+1FAFF)
- Miscellaneous Symbols (U+2600–U+27B0)
- Katakana, Bopomofo, Fullwidth Forms, и т.д.

---

## P1 — Баги и корректность

### 2.1 Показ ошибок сохранения файла

**Файл:** `EditorWindow.swift`, `StatusBarWindow.swift`, `Application.swift`

Пустой `catch {}` в `saveFile()` заменён на запись `lastError`. StatusBarWindow отображает ошибку красным цветом в центре строки состояния. Ошибка сбрасывается при следующем нажатии клавиши.

### 2.2 Удалён мёртвый код `Window.render()`

**Файл:** `Window.swift`

Метод `render(to:prevCells:)` (24 строки) был определён, но нигде не вызывался — рендеринг реализован в Application. Удалён.

### 2.3 Очищен LSPProtocol.swift

**Файл:** `LSP/LSPProtocol.swift`

Из 188 строк оставлено 10 — только `SemanticToken`. Удалены неиспользуемые Codable-типы: `LSPRequest`, `LSPNotification`, `LSPResponse`, `LSPInitializeParams`, `LSPClientCapabilities`, `LSPServerCapabilities`, `AnyCodable`, и ~20 других структур. LSPClient использует сырые `[String: Any]`.

### 2.4 Удалён недостижимый код в tokenizer

**Файл:** `SyntaxTokenizer.swift`

Ветка `word.hasPrefix("//")` внутри блока идентификаторов недостижима — символ `/` не входит в множество символов идентификатора. Удалена.

### 2.5 Исправлен парсинг чисел в tokenizer

**Файл:** `SyntaxTokenizer.swift`

Оригинальный код жадно захватывал символы `a-f` в любом числе (не только hex). Переписан:
- **Hex:** распознаётся по префиксу `0x`/`0X`, разрешены `0-9`, `a-f`, `A-F`, `_`
- **Decimal:** разрешены `0-9`, `.`, `e`/`E`, `_`, `+`/`-` после `e`/`E` (scientific notation)

---

## P1 — Производительность

### 3.1 Индекс токенов по словарю

**Файл:** `EditorWindow.swift`

`semanticTokens.filter { $0.line == line }` вызывался для каждой видимой строки каждого кадра — O(n) на строку. Заменён на `tokenIndex: [Int: [SemanticToken]]`, перестраиваемый при установке `semanticTokens` через `didSet`. Lookup стал O(1).

### 3.2 Плоский массив для prevScreenCells

**Файл:** `Application.swift` → `Renderer.swift`

`[Int: [Int: Cell]]` (словарь словарей) — двойной хеш-лукап на каждую ячейку экрана. Заменён на `[Cell?]` размером `width * height` с прямым индексированием `row * width + col`. При resize — пересоздание массива.

### 3.3 Кеширование markdown tokenizer state

**Файл:** `SyntaxTokenizer.swift`

Каждый кадр перечитывалось до 500 строк перед viewport для отслеживания состояния code block. Добавлен кеш: запоминается `scrollY` и `inCodeBlock` состояние. При следующем вызове, если scrollY близок к кешированному, сканирование начинается с кешированной позиции.

---

## P1 — Undo/Redo

### 4.1 Полная реализация Undo/Redo

**Файл:** `EditorWindow.swift`

Заглушки `undo()` / `redo()` заменены на полную реализацию:

- **Модель:** каждый editing action записывается как `(offset, deleted, inserted)`
- **Запись:** через `recordAction()` — добавляет в `undoStack`, очищает `redoStack`
- **Undo:** берёт последнюю запись, удаляет `inserted`, вставляет `deleted`, переносит в `redoStack`
- **Redo:** обратная операция
- **Флаг `isUndoRedoing`:** предотвращает запись undo/redo операций в стек

Покрыты все editing операции:
- `insertText`, `insertNewLineAtCursor`, `insertNewLineBelow`, `insertNewLineAbove`
- `deleteCharAtCursor`, `deleteBeforeCursor`, `deleteCurrentLine`
- `pasteAfter`, `pasteBefore`
- `deleteVisualSelection`, `deleteVisualLineSelection`
- `handleSubstitute`

---

## P2 — Асинхронные операции

### 5.1 Асинхронный поиск по проекту

**Файл:** `SearchWindow.swift`, `Application.swift`

Синхронный обход файловой системы блокировал event loop. Переписан:

- Поиск запускается в `Thread` с локальным массивом результатов
- Результат передаётся через глобальные переменные + `NSLock`
- `pollSearch()` вызывается в event loop, забирает результат, обновляет UI
- Во время поиска показывается «scanning...» в заголовке
- Spinner tick перерисовывает окно каждые 100мс

### 5.2 Асинхронные git-операции

**Файл:** `GitPanelWindow.swift`, `Application.swift`

`refresh()` запускал 3 последовательных git-процесса (branch, status, log), блокируя event loop на ~200-500мс. Переписан:

- Три git-команды запускаются в одном фоновом `Thread`
- Результат передаётся через глобальные переменные + `NSLock`
- `pollRefresh()` вызывается в event loop
- Во время refresh показывается «loading...» вместо branch name
- Instance-метод `runGit()` делегирует к статическому `runGitSync()` для использования из Thread

---

## P3 — Архитектурный рефакторинг

### 6.1 Выделен Renderer

**Новый файл:** `App/Renderer.swift`

Из Application извлечён класс `Renderer`, инкапсулирующий:
- `prevScreenCells: [Cell?]` — буфер предыдущего кадра
- `termFG/BG/Bold/Dim/Underline/Reverse` — состояние терминальных атрибутов
- `render(windows:cursorInfo:)` — diff-based рендеринг с оптимизацией атрибутов
- `ensureScreenSize()` — управление размером буфера
- `isWideChar()` — статический метод для определения двойной ширины символов

Application делегирует рендеринг: `renderer.render(windows:cursorInfo:)`.

### 6.2 Выделен LayoutManager

**Новый файл:** `App/LayoutManager.swift`

Чистая функция `LayoutManager.calculate()` принимает флаги видимости окон и размер терминала, возвращает 6 структур `WindowLayout` (explorer, editor, git, search, command, status). Application просто применяет результаты к окнам.

### 6.3 Введён протокол WindowDelegate

**Новый файл:** `App/WindowDelegate.swift`

Разрозненные closures (`onFileSelect`, `onResultSelect`, `onCommand`, `onRunCommand`, `onNeedsRender`, `onSearchComplete`, `onRefreshComplete`) объединены в один протокол:

```swift
protocol WindowDelegate: AnyObject {
    func openFile(_ path: String)
    func openFileAtLine(_ path: String, line: Int)
    func handleEditorCommand(_ cmd: String)
    func runGitCommand(label: String, args: [String])
    func requestRender()
}
```

- `Application` реализует протокол
- Базовый класс `Window` имеет `weak var delegate: WindowDelegate?`
- Каждое окно вызывает `delegate?.method()` вместо своего closure
- Устранены retain cycle (weak delegate вместо `[weak self]` в каждом closure)

---

## Итоговая структура файлов

```
Sources/Swim/
├── main.swift
├── App/
│   ├── Application.swift      (490 строк, было ~650)
│   ├── Renderer.swift         (148 строк) — НОВЫЙ
│   ├── LayoutManager.swift    (57 строк)  — НОВЫЙ
│   └── WindowDelegate.swift   (11 строк)  — НОВЫЙ
├── Core/
│   ├── Cell.swift
│   ├── Theme.swift
│   ├── Terminal.swift         (+30 строк: SIGWINCH self-pipe)
│   ├── PieceTable.swift
│   ├── Input.swift
│   └── SyntaxTokenizer.swift  (исправлен number parsing, markdown cache)
├── Window/
│   ├── Window.swift           (+delegate, −render)
│   ├── EditorWindow.swift     (+undo/redo, +tokenIndex)
│   ├── FileExplorerWindow.swift (исправлен displayWidth)
│   ├── GitPanelWindow.swift   (async refresh)
│   ├── SearchWindow.swift     (async search)
│   ├── StatusBarWindow.swift  (+errorMessage)
│   └── CommandWindow.swift    (+NSLock)
└── LSP/
    ├── LSPClient.swift
    └── LSPProtocol.swift      (178 строк → 10)
```

---

## Что не вошло в этот отчёт

Оставшиеся возможности для улучшения (не являются багами):

- **Incremental LSP sync** — сейчас при каждом нажатии клавиши отправляется полный текст файла (`getAllText()`). Для больших файлов стоит отправлять только изменения (LSP `textDocument/didChange` с range)
- **Incremental rendering** — пропуск обновления невидимых строк при горизонтальной прокрутке
- **Unicode-корректный word wrap** — длинные строки без пробелов выходят за пределы экрана
- **Множественные буферы** — сейчас один буфер на все окна
- **Конфигурируемая тема** — Theme захардкожена
