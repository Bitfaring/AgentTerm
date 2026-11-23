import Foundation
import SwiftTerm

/// A terminal view that tells what its emulator answers apart from what the
/// user types (#293). Both reach the terminal's delegate as bytes to send;
/// here the emulator's answers (which terminal it is, where the cursor is)
/// go to `onAnswer` instead, so that a replay of what a session once asked
/// its terminal can hold back only those, never a key the user typed
/// meanwhile.
open class AnsweringTerminalView: TerminalView {
    /// What the emulator answers, on the main thread, in order.
    public final var onAnswer: (@MainActor (Data) -> Void)?

    nonisolated open override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        // On the main thread after what was fed before it, as the view
        // itself sends it on.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let onAnswer = self.onAnswer {
                    onAnswer(bytes)
                } else {
                    self.terminalDelegate?.send(source: self, data: ArraySlice([UInt8](bytes)))
                }
            }
        }
    }
}
