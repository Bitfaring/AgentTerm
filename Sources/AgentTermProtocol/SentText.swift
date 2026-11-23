/// Text sent to a session as a whole rather than typed key by key: what is
/// written in the iPhone's message field, and a finished task's next
/// instruction given from a notification.
///
/// It arrives in one burst, and an agent takes a burst as pasted. A Return
/// that comes while the agent still counts the burst as pasted becomes part
/// of it instead of submitting it: Codex 0.169 kept a prompt of 437
/// characters in its input, the Return 80 ms after it a new line, and one of
/// 4,020 even with the Return 0.8 s after it; one of 229 it took (tried on
/// 2026-11-15). Bracketed paste says where the paste ends, and the Return
/// 80 ms after it submitted 4,000 characters in Claude Code, Codex, Copilot
/// CLI and Antigravity alike. So text longer than `typedLength`, or of
/// several lines, goes as a paste to a program that asked for bracketed
/// paste. Shorter text is typed as it is: a question that takes keys, a
/// permission's "1", takes it so.
public enum SentText {
    /// Longer than this, text is sent as a paste.
    public static let typedLength = 64

    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    /// What to send of `text`, before the Return that submits it: its lines
    /// ended with Return, as a terminal sends them.
    ///
    /// - Parameter bracketedPaste: Whether the program asked the terminal
    ///   for bracketed paste (mode 2004). One that did not would take the
    ///   brackets as text.
    public static func text(_ text: String, bracketedPaste: Bool) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        // No Escape goes, nor any other control character but a tab and the
        // ends of lines: in a paste the end of one would end it early, and
        // typed one would be a key, what follows it the key's sequence
        // (#248). Text from a page or a file's name may hold them.
        var kept = lines
        while kept.contains(pasteEnd) { kept = kept.replacingOccurrences(of: pasteEnd, with: "") }
        let typed = String(String.UnicodeScalarView(kept.unicodeScalars.filter(Self.goesInAPaste)))
        // "\r\n" is one Character to Swift: lines are counted once ended
        // the one way.
        guard bracketedPaste, typed.contains("\r") || typed.count > typedLength else { return typed }
        // With no Escape left, no end of a paste is in it, nor can one be
        // made of what was left once the ends that were in it went.
        return pasteStart + typed + pasteEnd
    }

    /// Whether a character is pasted: none of C0 but tab and Return, nor
    /// Delete, nor C1.
    static func goesInAPaste(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0D: return true
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return true
        }
    }
}
