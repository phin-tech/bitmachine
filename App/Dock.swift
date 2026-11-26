import AppKit
import BitMachineKit

/// Holds the player windows together the classic way (Docking does the geometry): dragging the Main Window drags
/// everything docked to it, dragging another drags it alone, both snap to other windows and the screen's edges, and
/// windows hanging under one that changes height move with it.
@MainActor
final class Dock {
    /// The Main Window first, then the others.
    private var windows: [NSWindow] = []
    private var main: NSWindow { windows[0] }
    private var visible: [NSWindow] { windows.filter(\.isVisible) }

    private struct Drag {
        let start: CGPoint
        let moving: [(window: NSWindow, origin: CGPoint)]
        let others: [CGRect]
    }

    private var drag: Drag?
    private var scaling = false

    func register(_ window: NSWindow) {
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self, weak window] _ in MainActor.assumeIsolated { self?.bringForward(around: window) }
        }
        if windows.count == 1 {
            // Minimizing the Main Window takes the others with it.
            NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideOthersWhileMinimized() }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showOthersAgain() }
            }
        }
    }

    // MARK: Dragging

    func beginDrag(_ window: NSWindow, at point: CGPoint) {
        let shown = visible
        let rects = shown.map(\.frame)
        guard let i = shown.firstIndex(of: window) else { return }
        let moving = window === main ? Docking.group(of: i, in: rects) : [i]
        drag = Drag(start: point,
                    moving: moving.sorted().map { (shown[$0], shown[$0].frame.origin) },
                    others: rects.indices.filter { !moving.contains($0) }.map { rects[$0] })
    }

    func continueDrag(to point: CGPoint) {
        guard let drag else { return }
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        let moved = drag.moving.map { CGRect(origin: CGPoint(x: $0.origin.x + dx, y: $0.origin.y + dy), size: $0.window.frame.size) }
        let box = Docking.bounds(moved)
        let screen = (drag.moving[0].window.screen ?? NSScreen.main)?.visibleFrame
        let snapped = Docking.snap(box, to: drag.others, screen: screen)
        for (window, origin) in drag.moving {
            window.setFrameOrigin(CGPoint(x: origin.x + dx + snapped.minX - box.minX, y: origin.y + dy + snapped.minY - box.minY))
        }
    }

    func endDrag() { drag = nil }

    var isDragging: Bool { drag != nil }

    // MARK: Sizes

    /// Gives a window a new frame; windows hanging under it follow its bottom edge.
    func setFrame(_ window: NSWindow, _ frame: CGRect) {
        let shown = visible
        guard !scaling, window.isVisible, let i = shown.firstIndex(of: window) else {
            window.setFrame(frame, display: true)
            return
        }
        let hanging = Docking.hanging(under: i, in: shown.map(\.frame))
        let dy = frame.minY - window.frame.minY
        window.setFrame(frame, display: true)
        for j in hanging {
            shown[j].setFrameOrigin(CGPoint(x: shown[j].frame.minX, y: shown[j].frame.minY + dy))
        }
    }

    /// Changes every window's scale (Double Size) and keeps the Main Window's Dock together, scaled about its top left.
    func scale(by factor: CGFloat, resizeAll: () -> Void) {
        let shown = visible
        let group = Docking.group(of: 0, in: shown.map(\.frame)).subtracting([0])
        let anchor = CGPoint(x: main.frame.minX, y: main.frame.maxY)
        let offsets = group.map { (shown[$0], $0) }.map { window, _ in
            (window, CGPoint(x: window.frame.minX - anchor.x, y: anchor.y - window.frame.maxY))
        }
        scaling = true
        resizeAll()
        scaling = false
        for (window, offset) in offsets {
            window.setFrameOrigin(CGPoint(x: anchor.x + offset.x * factor,
                                          y: anchor.y - offset.y * factor - window.frame.height))
        }
    }

    // MARK: Showing

    /// Puts a window under the lowest window docked to the Main Window, lined up with it on the left.
    func placeUnderDock(_ window: NSWindow) {
        let shown = visible.filter { $0 !== window }
        let group = Docking.group(of: 0, in: shown.map(\.frame))
        let lowest = group.map { shown[$0] }.min { $0.frame.minY < $1.frame.minY } ?? main
        window.setFrameOrigin(CGPoint(x: main.frame.minX, y: lowest.frame.minY - window.frame.height))
    }

    /// Keeps the player windows together in front when one of them comes forward.
    private func bringForward(around key: NSWindow?) {
        guard let key, drag == nil else { return }
        for window in visible where window !== key { window.order(.below, relativeTo: key.windowNumber) }
    }

    private var hiddenWhileMinimized: [NSWindow] = []

    private func hideOthersWhileMinimized() {
        hiddenWhileMinimized = visible.filter { $0 !== main }
        hiddenWhileMinimized.forEach { $0.orderOut(nil) }
    }

    private func showOthersAgain() {
        hiddenWhileMinimized.forEach { $0.orderFront(nil) }
        hiddenWhileMinimized = []
    }
}
