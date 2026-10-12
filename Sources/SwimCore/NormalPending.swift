import Foundation

/// Незавершённая командная последовательность normal-режима — vim-модель
/// грамматики `[count1] оператор [count2] движение`:
/// - `count` — счёт ДО оператора (`3dd`);
/// - `op` — взведённый оператор d/y/c (operator-pending);
/// - `opCount` — счёт ПОСЛЕ оператора (`d3d`);
/// - `gPrefix` — g-префикс двухбуквенных команд (`gg`/`gt`/`gT`/`gb`/`gd`).
///   Живёт отдельно от оператора: `dgg` взводит d и g одновременно —
///   g это часть движения, а не оператор, и не должен его вытеснять.
///
/// Дисциплина (инвариант потребителя): обработчик ключа ЛИБО явно
/// сохраняет последовательность (`keepPending`-флаг в arm-точке —
/// взведение оператора/g-префикса, накопление счёта — ранний return
/// ДО defer), ЛИБО она умирает одним сбросом на хвосте — посторонний
/// ключ и любой уход в другой режим (insert/visual/командная строка)
/// не оставляют «дозаказа» (класс утечки: `d v … Esc d` → `dd`).
/// Глобальные перехваты Application обходят handleKey — их точки
/// сбрасывают через `EditorWindow.interruptPending()`/`enterCommandMode`.
///
/// Слоты оператора и g-префикса независимы; операторов три: d/y/c
/// (last-wins внутри слота). Счёты vim-правило перемножает при
/// потреблении: `2d3d` = 6 строк.
public struct NormalPending: Equatable {
    public enum Op: Equatable {
        case d, y, c
    }

    /// Максимальный счёт (как в vim) — защита repeat-циклов потребителя.
    public static let countCap = 999_999

    public private(set) var count: Int?
    public private(set) var op: Op?
    public private(set) var opCount: Int?
    public private(set) var gPrefix = false

    public init() {}

    public var isEmpty: Bool { count == nil && opCount == nil && op == nil && !gPrefix }

    /// Цифра счёта в АКТИВНЫЙ слот: оператор взведён → `opCount` (`d3d`),
    /// иначе → `count` (`3dd`). Голый ведущий `0` в активном слоте — не
    /// цифра (движение в начало строки, `d0`): false без мутаций.
    @discardableResult
    public mutating func appendDigit(_ d: Int) -> Bool {
        let target = op != nil ? opCount : count
        guard d > 0 || target != nil else { return false }
        let acc = min((target ?? 0) * 10 + d, Self.countCap)
        if op != nil { opCount = acc } else { count = acc }
        return true
    }

    /// Взвести оператор — замещает любой предыдущий (last-wins).
    /// Потребление явного API не имеет: оператор читается напрямую
    /// (`pending.op`), слот умирает на хвостовом defer/reset —
    /// take-паттерн остался только у счёта (единственная точка
    /// потребления на ключ).
    public mutating func arm(_ op: Op) {
        self.op = op
    }

    /// Взвести / потребить g-префикс.
    public mutating func armGPrefix() { gPrefix = true }

    @discardableResult
    public mutating func takeGPrefix() -> Bool {
        guard gPrefix else { return false }
        gPrefix = false
        return true
    }

    /// Эффективный счёт: vim перемножает счёты по обе стороны оператора
    /// (`2d3w` = 6); nil — счёта не было вовсе. Без fallback-параметра
    /// сознательно: смешение 1-based счёта со значением в домене
    /// вызывающего (0-based строка) — острый край, уже давший off-by-one;
    /// домен falling back'а принадлежит вызывающему (`?? 1`).
    public mutating func takeCount() -> Int? {
        defer {
            count = nil
            opCount = nil
        }
        switch (count, opCount) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return min(a * b, Self.countCap)
        }
    }

    /// Полный сброс (хвост обработчика, перехват paste).
    public mutating func reset() {
        count = nil
        opCount = nil
        op = nil
        gPrefix = false
    }
}
