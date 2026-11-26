import CoreGraphics

/// How the player windows hold together: which touch (a Dock), where a moved window snaps, and which follow a window
/// that changes size. Rects are in screen coordinates, y up, as AppKit has them.
public enum Docking {
    /// Edges closer than this snap together, as in classic players.
    public static let snapDistance: CGFloat = 15

    /// Whether two windows touch: an edge of one on an edge of the other, overlapping along it.
    public static func touch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance
        let stacked = (abs(a.maxY - b.minY) <= tolerance || abs(b.maxY - a.minY) <= tolerance) && overlapX
        let sideBySide = (abs(a.maxX - b.minX) <= tolerance || abs(b.maxX - a.minX) <= tolerance) && overlapY
        return stacked || sideBySide
    }

    /// The Dock a window is in: it and every window touching it, and every window touching those.
    public static func group(of start: Int, in rects: [CGRect]) -> Set<Int> {
        var found: Set<Int> = [start]
        var queue = [start]
        while let i = queue.popLast() {
            for j in rects.indices where !found.contains(j) && touch(rects[i], rects[j]) {
                found.insert(j)
                queue.append(j)
            }
        }
        return found
    }

    /// Where `rect`, dragged to here, should go: each axis moves by the smallest nudge that brings one of its edges
    /// onto an edge of another window (or the screen) within `distance`, if any does.
    public static func snap(_ rect: CGRect, to others: [CGRect], screen: CGRect?, distance: CGFloat = snapDistance) -> CGRect {
        var dx: CGFloat?, dy: CGFloat?
        func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
            if abs(delta) <= distance, abs(delta) < abs(best ?? .infinity) { best = delta }
        }
        for o in others {
            // Only edges the window could actually sit against: overlapping, or nearly, on the other axis.
            let nearY = rect.minY < o.maxY + distance && o.minY < rect.maxY + distance
            let nearX = rect.minX < o.maxX + distance && o.minX < rect.maxX + distance
            if nearY {
                for delta in [o.maxX - rect.minX, o.minX - rect.maxX, o.minX - rect.minX, o.maxX - rect.maxX] {
                    consider(delta, &dx)
                }
            }
            if nearX {
                for delta in [o.maxY - rect.minY, o.minY - rect.maxY, o.minY - rect.minY, o.maxY - rect.maxY] {
                    consider(delta, &dy)
                }
            }
        }
        if let screen {
            for delta in [screen.minX - rect.minX, screen.maxX - rect.maxX] { consider(delta, &dx) }
            for delta in [screen.minY - rect.minY, screen.maxY - rect.maxY] { consider(delta, &dy) }
        }
        return rect.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
    }

    /// The windows hanging under window `index`: those whose top sits on its bottom, and those under them, in turn.
    /// When it changes height, they move with its bottom edge.
    public static func hanging(under index: Int, in rects: [CGRect], tolerance: CGFloat = 1) -> [Int] {
        var found: [Int] = []
        var queue = [index]
        while let i = queue.popLast() {
            let bottom = rects[i]
            for j in rects.indices where j != index && !found.contains(j) {
                let r = rects[j]
                let overlapX = min(r.maxX, bottom.maxX) - max(r.minX, bottom.minX) > tolerance
                if overlapX, abs(r.maxY - bottom.minY) <= tolerance {
                    found.append(j)
                    queue.append(j)
                }
            }
        }
        return found
    }

    /// The bounding box of some windows.
    public static func bounds(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }
}
