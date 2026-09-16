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
    case ctrlUp
    case ctrlDown
    case ctrlLeft
    case ctrlRight
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
                // '[' — CSI sequence: scan parameter bytes (0x30–0x3F) up
                // to a final byte (0x40–0x7E), then dispatch on the
                // (params, final) pair — see csiKey(params:final:).
                var params = ""
                var finalByte: UInt8? = nil
                while let byte = terminal.readByte() {
                    if byte >= 0x30 && byte <= 0x3F {
                        params.append(Character(UnicodeScalar(byte)))
                    } else if byte >= 0x20 && byte <= 0x2F {
                        continue // intermediate bytes — ignored
                    } else {
                        finalByte = byte
                        break
                    }
                }
                guard let fin = finalByte else {
                    return .unknown("\u{1b}[" + params)
                }
                if let key = Self.csiKey(params: params, final: fin) {
                    return key
                }
                return .unknown("\u{1b}[\(params)\(String(UnicodeScalar(fin)))")
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
        if b == 127 { return .backspace }
        // 0x08 is Ctrl+H in modern terminals (Backspace sends 127);
        // it falls through to the C0 branch below and becomes .ctrl("h")
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

    /// Maps a scanned CSI sequence — the parameter string between `ESC [`
    /// and the final byte — to a key. Covers the encodings mainstream
    /// terminals actually send: plain arrows and tilde codes, rxvt-style
    /// and xterm-style modified arrows, and CSI u (kitty / xterm
    /// modifyOtherKeys) for keys with no legacy encoding.
    static func csiKey(params: String, final: UInt8) -> Key? {
        switch final {
        case 65, 66, 67, 68: // A B C D — arrows
            let ctrl = params == "1;5" || params == "5" || params == ";5"
            switch final {
            case 65: return ctrl ? .ctrlUp : .up
            case 66: return ctrl ? .ctrlDown : .down
            case 67: return ctrl ? .ctrlRight : .right
            default: return ctrl ? .ctrlLeft : .left
            }
        case 72: return .home
        case 70: return .end
        case 90: return .shiftTab
        case 117: // 'u' — CSI u
            if params == "13" { return .enter }
            return nil
        case 126: // '~'
            switch params {
            case "1": return .home
            case "2": return .insert
            case "3": return .delete
            case "4": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            case "20": return .f(9)
            case "21": return .f(10)
            case "23": return .f(11)
            case "24": return .f(12)
            default: return nil
            }
        default:
            return nil
        }
    }
}

extension Key {
    var insertableChar: Character? {
        if case .char(let c) = self { return c }
        return nil
    }
}
