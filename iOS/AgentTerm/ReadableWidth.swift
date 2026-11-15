import SwiftUI

/// On the iPad's screen (#88), what is read in a column keeps a column's
/// width, in the middle, with its background and scroll bar still at the
/// screen's edges. On the iPhone, and on an iPad narrowed by Split View or
/// Stage Manager, nothing changes.
struct ReadableWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// About as wide as a line is comfortable to read.
    static let maximum: CGFloat = 760

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad, sizeClass == .regular {
            GeometryReader { proxy in
                content.contentMargins(.horizontal, max(0, (proxy.size.width - Self.maximum) / 2), for: .scrollContent)
            }
        } else {
            content
        }
    }
}

extension View {
    /// The scroll views inside keep a column's width on the iPad (`ReadableWidth`).
    func readableWidth() -> some View { modifier(ReadableWidth()) }
}
