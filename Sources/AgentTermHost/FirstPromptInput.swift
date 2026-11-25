import Foundation

/// Recognizes text followed by Return in the terminal input stream, without
/// retaining the user's message. Frames may split a paste or a key sequence.
struct FirstPromptInput {
    private var characters = 0
    private var escaped = false
    private var sequence: [UInt8]?
    private var pasting = false

    mutating func submitted(_ data: Data) -> Bool {
        for byte in data {
            if let parameters = sequence {
                if (0x40...0x7e).contains(byte) {
                    if byte == 0x7e {
                        if parameters == Array("200".utf8) { pasting = true }
                        if parameters == Array("201".utf8) { pasting = false }
                    }
                    sequence = nil
                } else if parameters.count < 16 {
                    sequence?.append(byte)
                }
            } else if escaped {
                escaped = false
                if byte == 0x5b || byte == 0x4f { sequence = [] }
            } else {
                switch byte {
                case 0x1b: escaped = true
                case 0x0d, 0x0a:
                    if !pasting && characters > 0 { return true }
                case 0x03, 0x15: characters = 0  // Cancel or clear the line.
                case 0x08, 0x7f: characters = max(0, characters - 1)
                case 0x20...0x7e, 0xc2...0xf4: characters += 1
                default: break
                }
            }
        }
        return false
    }
}
