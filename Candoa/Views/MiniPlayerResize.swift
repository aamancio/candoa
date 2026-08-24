import AppKit
import SwiftUI

internal enum MiniPlayerResizeEdge: String, CaseIterable, Identifiable {
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var isCorner: Bool {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return true
        case .top, .bottom, .leading, .trailing:
            return false
        }
    }

    var anchorsTrailing: Bool {
        switch self {
        case .leading, .topLeading, .bottomLeading:
            return true
        case .top, .bottom, .trailing, .topTrailing, .bottomTrailing:
            return false
        }
    }

    var anchorsBottom: Bool {
        switch self {
        case .top, .topLeading, .topTrailing:
            return true
        case .bottom, .leading, .trailing, .bottomLeading, .bottomTrailing:
            return false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom:
            return .resizeUpDown
        case .leading, .trailing:
            return MiniPlayerResizeCursor.horizontal
        case .topLeading:
            return MiniPlayerResizeCursor.topLeft
        case .topTrailing:
            return MiniPlayerResizeCursor.topRight
        case .bottomLeading:
            return MiniPlayerResizeCursor.bottomLeft
        case .bottomTrailing:
            return MiniPlayerResizeCursor.bottomRight
        }
    }

    func width(in size: CGSize) -> CGFloat {
        switch self {
        case .top, .bottom:
            return size.width
        case .leading, .trailing:
            return MiniPlayerLayout.resizeHitThickness
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return MiniPlayerLayout.resizeCornerLength
        }
    }

    func height(in size: CGSize) -> CGFloat {
        switch self {
        case .top, .bottom:
            return MiniPlayerLayout.resizeHitThickness
        case .leading, .trailing:
            return size.height
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return MiniPlayerLayout.resizeCornerLength
        }
    }

    func position(in size: CGSize) -> CGPoint {
        let edgeInset = MiniPlayerLayout.resizeHitThickness / 2
        let cornerInset = MiniPlayerLayout.resizeCornerLength / 2

        switch self {
        case .top:
            return CGPoint(x: size.width / 2, y: edgeInset)
        case .bottom:
            return CGPoint(x: size.width / 2, y: size.height - edgeInset)
        case .leading:
            return CGPoint(x: edgeInset, y: size.height / 2)
        case .trailing:
            return CGPoint(x: size.width - edgeInset, y: size.height / 2)
        case .topLeading:
            return CGPoint(x: cornerInset, y: cornerInset)
        case .topTrailing:
            return CGPoint(x: size.width - cornerInset, y: cornerInset)
        case .bottomLeading:
            return CGPoint(x: cornerInset, y: size.height - cornerInset)
        case .bottomTrailing:
            return CGPoint(x: size.width - cornerInset, y: size.height - cornerInset)
        }
    }

    /// The width change a drag on this edge asks for. Vertical drags come
    /// through the player's current shape, so a portrait player follows the
    /// pointer as closely as a landscape one.
    func widthDelta(for translation: CGSize, aspectRatio: CGFloat) -> CGFloat {
        let candidates: [CGFloat]

        switch self {
        case .top:
            candidates = [-translation.height * aspectRatio]
        case .bottom:
            candidates = [translation.height * aspectRatio]
        case .leading:
            candidates = [-translation.width]
        case .trailing:
            candidates = [translation.width]
        case .topLeading:
            candidates = [
                -translation.width,
                -translation.height * aspectRatio
            ]
        case .topTrailing:
            candidates = [
                translation.width,
                -translation.height * aspectRatio
            ]
        case .bottomLeading:
            candidates = [
                -translation.width,
                translation.height * aspectRatio
            ]
        case .bottomTrailing:
            candidates = [
                translation.width,
                translation.height * aspectRatio
            ]
        }

        return candidates.max { abs($0) < abs($1) } ?? 0
    }
}

private enum MiniPlayerResizeCursor {
    static var horizontal: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.columnResize(directions: .all)
        }
        return .resizeLeftRight
    }

    static var topLeft: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topLeft, directions: .all)
        }
        return northwestSoutheastFallback
    }

    static var topRight: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topRight, directions: .all)
        }
        return northeastSouthwestFallback
    }

    static var bottomLeft: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
        return northeastSouthwestFallback
    }

    static var bottomRight: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return northwestSoutheastFallback
    }

    nonisolated(unsafe) private static let northwestSoutheastFallback = fallbackResizeCursor(
        from: CGPoint(x: 4, y: 14),
        to: CGPoint(x: 14, y: 4)
    )

    nonisolated(unsafe) private static let northeastSouthwestFallback = fallbackResizeCursor(
        from: CGPoint(x: 14, y: 14),
        to: CGPoint(x: 4, y: 4)
    )

    private static func fallbackResizeCursor(from start: CGPoint, to end: CGPoint) -> NSCursor {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            appendLine(to: path, from: start, to: end)
            appendArrowHead(to: path, tip: start, tail: end)
            appendArrowHead(to: path, tip: end, tail: start)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 4
            path.stroke()

            NSColor.black.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2
            path.stroke()

            return true
        }

        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private static func appendLine(to path: NSBezierPath, from start: CGPoint, to end: CGPoint) {
        path.move(to: start)
        path.line(to: end)
    }

    private static func appendArrowHead(to path: NSBezierPath, tip: CGPoint, tail: CGPoint) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let headLength: CGFloat = 5
        let spread: CGFloat = 0.72

        for offset in [-spread, spread] {
            let backAngle = angle + .pi + offset
            let point = CGPoint(
                x: tip.x + CGFloat(cos(Double(backAngle))) * headLength,
                y: tip.y + CGFloat(sin(Double(backAngle))) * headLength
            )
            appendLine(to: path, from: tip, to: point)
        }
    }
}

internal struct MiniPlayerResizeHandle: View {
    let edge: MiniPlayerResizeEdge

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .candoaCursor(edge.cursor)
            .help("Resize")
    }
}
