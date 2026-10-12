import Foundation

/// Незавершённая командная последовательность normal-режима:
/// накопленный числовой префикс (1–9, затем 0) + однобуквенный
/// префикс-оператор (g / d / y). Одна точка правды для всего
/// «отложенного» состояния ввода: сброс — одним `reset()`, мутации
/// типизированы, потребление явное (`takeOp`/`takeCount`).
///
/// Дисциплина (инвариант потребителя): обработчик ключа ЛИБО явно
/// сохраняет последовательность (`keep`-флаг в arm-точке обработчика —
/// взведение префикса, накопление счёта), ЛИБО она умирает одним
/// сбросом на хвосте — postоронний ключ и любой уход в другой режим
/// (insert/visual/командная строка) не оставляют «дозаказа»
/// (класс утечки: `d v … Esc d` → `dd`).
///
/// Слот оператора один — последний префикс вытесняет предыдущий
/// (равномерно; разрозненная реализация позволяла d и y быть
/// взведёнными одновременно — случайность, не семантика). Счёт не
/// привязан к оператору: потребляет тот, кто умеет (`gg`/`G`);
/// `dd`/`yy` счёт не используют (задокументированный quirk).
public struct NormalPending: Equatable {
    public enum Op: Equatable {
        case g, d, y
    }

    public private(set) var count: Int?
    public private(set) var op: Op?

    public init() {}

    public var isEmpty: Bool { count == nil && op == nil }
    public var hasCount: Bool { count != nil }
    public var hasOp: Bool { op != nil }

    /// Цифра счёта. Голый ведущий `0` — не цифра (прыжок в колонку):
    /// возвращает false, состояние не трогает.
    @discardableResult
    public mutating func appendDigit(_ d: Int) -> Bool {
        guard d > 0 || count != nil else { return false }
        count = (count ?? 0) * 10 + d
        return true
    }

    /// Взвести префикс — замещает любой предыдущий (last-wins).
    public mutating func arm(_ op: Op) {
        self.op = op
    }

    /// Потребить префикс, если взведён именно он.
    @discardableResult
    public mutating func takeOp(_ op: Op) -> Bool {
        guard self.op == op else { return false }
        self.op = nil
        return true
    }

    /// Потребить накопленный счёт (nil — счёта не было). Без
    /// fallback-параметра сознательно: смешение 1-based счёта со
    /// значением в домене вызывающего (0-based строка) — острый край,
    /// уже давший off-by-one; домен falling back'a принадлежит arm'у.
    public mutating func takeCount() -> Int? {
        defer { count = nil }
        return count
    }

    /// Полный сброс (хвост обработчика, перехват paste).
    public mutating func reset() {
        count = nil
        op = nil
    }
}
