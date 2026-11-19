import SwiftUI

/// The × that closes a tab, a page, a group or a session (#169): a control
/// of its own size, 18 points square, not its 9-point glyph's, with a
/// background while the pointer is over it, so that a click beside the
/// glyph closes rather than selects.
struct CloseButton: View {
    let help: String
    var glyph: CGFloat = 9
    let action: () -> Void
    @State private var hovering = false

    static let side: CGFloat = 18

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: glyph, weight: .bold))
                .frame(width: Self.side, height: Self.side)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hovering ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
