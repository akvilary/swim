import Foundation

struct SemanticToken: Equatable {
    let line: Int
    let startChar: Int
    let length: Int
    let type: String
    let modifiers: Int
}
