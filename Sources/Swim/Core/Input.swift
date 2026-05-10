enum Key: Equatable {
    case char(Character)
    case escape
    case enter
    case backspace
    case delete
    case tab
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case ctrl(Character)
    case f(Int)
    case shiftTab
    case insert
    case unknown(String)

    static func parse(from terminal: Terminal) -> Key? {
        guard let b = terminal.readByte() else { return nil }

        if b == 27 {
            if !terminal.bytesAvailable() {
                return .escape
            }
            guard let b2 = terminal.readByte() else { return .escape }

            if b2 == 91 {
                guard let b3 = terminal.readByte() else { return .unknown("\u{1b}[") }
                switch b3 {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 72: return .home
                case 70: return .end
                case 53:
                    if let b4 = terminal.readByte(), b4 == 126 { return .pageUp }
                    return .unknown("\u{1b}[5")
                case 54:
                    if let b4 = terminal.readByte(), b4 == 126 { return .pageDown }
                    return .unknown("\u{1b}[6")
                case 49:
                    if let b4 = terminal.readByte() {
                        if b4 == 126 { return .home }
                        if b4 == 59, let b5 = terminal.readByte(), b5 == 50 {
                            if let b6 = terminal.readByte() {
                                switch b6 {
                                case 65: return .up
                                case 66: return .down
                                case 67: return .right
                                case 68: return .left
                                case 72: return .home
                                case 70: return .end
                                default: return .unknown("\u{1b}[1;2\(String(UnicodeScalar(b6)))")
                                }
                            }
                        }
                        if b4 == 59, let b5 = terminal.readByte(), b5 == 53 {
                            if let b6 = terminal.readByte() {
                                switch b6 {
                                case 65: return .f(1)
                                case 66: return .f(2)
                                case 67: return .f(3)
                                case 68: return .f(4)
                                case 69: return .f(5)
                                default: return .unknown("\u{1b}[1;5\(String(UnicodeScalar(b6)))")
                                }
                            }
                        }
                    }
                    return .unknown("\u{1b}[1")
                case 50:
                    if let b4 = terminal.readByte() {
                        if b4 == 126 { return .insert }
                        if b4 == 48, let b5 = terminal.readByte(), b5 == 126 { return .f(9) }
                        if b4 == 49, let b5 = terminal.readByte(), b5 == 126 { return .f(10) }
                        if b4 == 51, let b5 = terminal.readByte(), b5 == 126 { return .f(11) }
                        if b4 == 52, let b5 = terminal.readByte(), b5 == 126 { return .f(12) }
                    }
                    return .unknown("\u{1b}[2")
                case 51:
                    if let b4 = terminal.readByte(), b4 == 126 { return .delete }
                    return .unknown("\u{1b}[3")
                case 52:
                    if let b4 = terminal.readByte(), b4 == 126 { return .end }
                    return .unknown("\u{1b}[4")
                case 90: return .shiftTab
                case 59:
                    if let b4 = terminal.readByte(), b4 == 53 {
                        if let b5 = terminal.readByte() {
                            switch b5 {
                            case 65: return .ctrl("p")
                            case 66: return .ctrl("n")
                            case 67: return .ctrl("f")
                            case 68: return .ctrl("b")
                            case 72: return .home
                            case 70: return .end
                            default: return .unknown("\u{1b}[;5\(String(UnicodeScalar(b5)))")
                            }
                        }
                    }
                    return .unknown("\u{1b}[;")
                default: return .unknown("\u{1b}[\(String(UnicodeScalar(b3)))")
                }
            } else if b2 == 79 {
                guard let b3 = terminal.readByte() else { return .unknown("\u{1b}O") }
                switch b3 {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 72: return .home
                case 70: return .end
                case 80: return .f(1)
                case 81: return .f(2)
                case 82: return .f(3)
                case 83: return .f(4)
                default: return .unknown("\u{1b}O\(String(UnicodeScalar(b3)))")
                }
            }
            return .unknown("\u{1b}\(String(UnicodeScalar(b2)))")
        }

        if b == 13 { return .enter }
        if b == 127 || b == 8 { return .backspace }
        if b == 9 { return .tab }
        if b == 4 { return .ctrl("d") }

        if b >= 1 && b <= 26 {
            return .ctrl(Character(UnicodeScalar(UInt8(b + 96))))
        }

        if b >= 32 && b <= 126 {
            return .char(Character(UnicodeScalar(b)))
        }

        if b >= 194 && b <= 244 {
            var bytes = [b]
            let cont: Int
            if b < 224 { cont = 1 }
            else if b < 240 { cont = 2 }
            else { cont = 3 }
            for _ in 0..<cont {
                if let next = terminal.readByte() { bytes.append(next) }
                else { break }
            }
            if let str = String(bytes: bytes, encoding: .utf8), let c = str.first {
                return .char(c)
            }
            return nil
        }

        return nil
    }
}

extension Key {
    var insertableChar: Character? {
        if case .char(let c) = self { return c }
        return nil
    }
}
