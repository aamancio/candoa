import AppKit
import SwiftUI

enum AISidebarLayout {
    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 720
    static let resizeHandleHitWidth: CGFloat = 12
    static let slideAnimationDuration: TimeInterval = 0.18
}

struct AISidebarResizeHandle: View {
    let isResizing: Bool
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(CandoaChromeStyle.sidebarTextSecondary.opacity(isActive ? 0.64 : 0.28))
                .frame(width: isActive ? 3 : 1)
                .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .candoaAISidebarCursor(AISidebarResizeCursor.horizontal)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Resize Agent Sidebar")
    }

    private var isActive: Bool {
        isHovering || isResizing
    }
}

enum AISidebarResizeCursor {
    static var horizontal: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.columnResize(directions: .all)
        }
        return .resizeLeftRight
    }
}

struct AISidebarCursorHoverModifier: ViewModifier {
    let cursor: NSCursor
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                updateCursor(isHovering: isHovering)
            }
            .onDisappear {
                updateCursor(isHovering: false)
            }
    }

    private func updateCursor(isHovering: Bool) {
        guard isHovering != hasPushedCursor else { return }
        hasPushedCursor = isHovering
        if isHovering {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}

extension View {
    func candoaAISidebarCursor(_ cursor: NSCursor) -> some View {
        modifier(AISidebarCursorHoverModifier(cursor: cursor))
    }
}
