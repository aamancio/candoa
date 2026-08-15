import AppKit
import SwiftUI

internal struct CursorHoverModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content
            .background(CursorRectView(cursor: cursor))
            .onContinuousHover { phase in
                if case .active = phase {
                    cursor.set()
                }
            }
            .onHover { isHovering in
                if isHovering {
                    cursor.set()
                }
            }
    }
}

internal struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let view = CursorRectNSView(frame: .zero)
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
    }
}

internal final class CursorRectNSView: NSView {
    var cursor: NSCursor = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}

extension View {
    // Cursor for chrome floating over web content: WebKit re-asserts its
    // own cursor on every mouse move, so a one-shot push is not enough —
    // this pairs an AppKit cursor rect with continuous re-assertion.
    func candoaCursor(_ cursor: NSCursor) -> some View {
        modifier(CursorHoverModifier(cursor: cursor))
    }
}
