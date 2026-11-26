import CoreGraphics
import Foundation

// Sprite coordinates and positions follow Webamp's skinSprites.ts and css/playlist-window.css (MIT; see
// THIRD_PARTY_NOTICES.md).

public enum PlaylistSprites {
    public static func topLeft(_ focused: Bool) -> Sprite { Sprite(.pledit, 0, focused ? 0 : 21, 25, 20) }
    public static func title(_ focused: Bool) -> Sprite { Sprite(.pledit, 26, focused ? 0 : 21, 100, 20) }
    public static func topTile(_ focused: Bool) -> Sprite { Sprite(.pledit, 127, focused ? 0 : 21, 25, 20) }
    public static func topRight(_ focused: Bool) -> Sprite { Sprite(.pledit, 153, focused ? 0 : 21, 25, 20) }
    public static let leftTile = Sprite(.pledit, 0, 42, 12, 29)
    public static let rightTile = Sprite(.pledit, 31, 42, 20, 29)
    public static let bottomTile = Sprite(.pledit, 179, 0, 25, 38)
    public static let bottomLeft = Sprite(.pledit, 0, 72, 125, 38)
    public static let bottomRight = Sprite(.pledit, 126, 72, 150, 38)
    public static let scrollHandle = Sprite(.pledit, 52, 53, 8, 18)
    public static let scrollHandleSelected = Sprite(.pledit, 61, 53, 8, 18)
    public static let closePressed = Sprite(.pledit, 52, 42, 9, 9)
    public static let shadePressed = Sprite(.pledit, 62, 42, 9, 9)
}

/// What the Playlist Window shows, apart from the list's text, which the app draws in a real font.
public struct PlaylistWindowState: Equatable, Sendable {
    /// In skin pixels: 275 wide and 116 high at the least, growing in steps of 25 and 29.
    public var size = PlaylistLayout.defaultSize
    public var isFocused = true
    /// The first row showing.
    public var scroll = 0
    public var rowCount = 0
    public var pressed: PlaylistControl?
    /// "selected/total" running time, as the bottom-right shows it.
    public var runningTime = ""
    /// The current Track's time, beside the mini transport; empty when stopped.
    public var miniTime = ""
    public init() {}
}

public enum PlaylistMenu: Hashable, Sendable { case add, remove, select, misc, list }

public enum PlaylistControl: Hashable, Sendable {
    case titleBar, close, shade, list, scrollbar, resize
    case menu(PlaylistMenu)
    case transport(TransportButton)
}

public enum PlaylistLayout {
    public static let defaultSize = CGSize(width: 275, height: 232)
    public static let minimumSize = CGSize(width: 275, height: 116)
    public static let rowHeight: CGFloat = 13

    /// The nearest size the frame's tiles allow.
    public static func snapped(_ size: CGSize) -> CGSize {
        let w = max(minimumSize.width, minimumSize.width + ((size.width - minimumSize.width) / 25).rounded() * 25)
        let h = max(minimumSize.height, minimumSize.height + ((size.height - minimumSize.height) / 29).rounded() * 29)
        return CGSize(width: w, height: h)
    }

    /// Where the rows are, inside the frame (with the 3-pixel margin at the top the list keeps).
    public static func list(_ size: CGSize) -> CGRect {
        CGRect(x: 12, y: 23, width: size.width - 32, height: size.height - 20 - 38 - 6)
    }

    public static func visibleRows(_ size: CGSize) -> Int { max(Int(list(size).height / rowHeight), 1) }

    public static func row(at y: CGFloat, size: CGSize, scroll: Int) -> Int? {
        let list = list(size)
        guard y >= list.minY, y < list.maxY else { return nil }
        return scroll + Int((y - list.minY) / rowHeight)
    }

    public static func scrollTrack(_ size: CGSize) -> CGRect {
        CGRect(x: size.width - 15, y: 20, width: 8, height: size.height - 20 - 38)
    }

    public static func maxScroll(rows: Int, size: CGSize) -> Int { max(rows - visibleRows(size), 0) }

    public static func handleY(scroll: Int, rows: Int, size: CGSize) -> CGFloat {
        let track = scrollTrack(size)
        let most = maxScroll(rows: rows, size: size)
        guard most > 0 else { return track.minY }
        return track.minY + ((track.height - 18) * CGFloat(scroll) / CGFloat(most)).rounded()
    }

    /// The first row for a drag of the scroll handle to `y`.
    public static func scroll(atY y: CGFloat, rows: Int, size: CGSize) -> Int {
        let track = scrollTrack(size)
        let fraction = min(max((y - track.minY - 9) / max(track.height - 18, 1), 0), 1)
        return Int((fraction * CGFloat(maxScroll(rows: rows, size: size))).rounded())
    }

    public static func close(_ size: CGSize) -> CGRect { CGRect(x: size.width - 11, y: 3, width: 9, height: 9) }
    public static func shade(_ size: CGSize) -> CGRect { CGRect(x: size.width - 21, y: 3, width: 9, height: 9) }
    public static func resize(_ size: CGSize) -> CGRect {
        CGRect(x: size.width - 20, y: size.height - 20, width: 20, height: 20)
    }

    public static func menu(_ menu: PlaylistMenu, _ size: CGSize) -> CGRect {
        let y = size.height - 30
        switch menu {
        case .add: return CGRect(x: 14, y: y, width: 22, height: 18)
        case .remove: return CGRect(x: 43, y: y, width: 22, height: 18)
        case .select: return CGRect(x: 72, y: y, width: 22, height: 18)
        case .misc: return CGRect(x: 101, y: y, width: 22, height: 18)
        case .list: return CGRect(x: size.width - 44, y: y, width: 22, height: 18)
        }
    }

    public static func transport(_ button: TransportButton, _ size: CGSize) -> CGRect {
        let i = TransportButton.allCases.firstIndex(of: button)!
        return CGRect(x: size.width - 150 + 3 + CGFloat(i * 10), y: size.height - 38 + 22, width: 10, height: 10)
    }

    public static func runningTime(_ size: CGSize) -> CGPoint { CGPoint(x: size.width - 150 + 7, y: size.height - 38 + 10) }
    public static func miniTime(_ size: CGSize) -> CGPoint { CGPoint(x: size.width - 150 + 66, y: size.height - 38 + 23) }

    public static func control(at p: CGPoint, size: CGSize) -> PlaylistControl? {
        if close(size).contains(p) { return .close }
        if shade(size).contains(p) { return .shade }
        for m in [PlaylistMenu.add, .remove, .select, .misc, .list] where menu(m, size).contains(p) { return .menu(m) }
        for b in TransportButton.allCases where transport(b, size).contains(p) { return .transport(b) }
        if resize(size).contains(p) { return .resize }
        if scrollTrack(size).insetBy(dx: -2, dy: 0).contains(p) { return .scrollbar }
        if list(size).contains(p) { return .list }
        if p.y < 20 { return .titleBar }
        return nil
    }

    public static func placements(for state: PlaylistWindowState) -> [MainWindowLayout.Placement] {
        var out: [MainWindowLayout.Placement] = []
        func put(_ s: Sprite, _ x: CGFloat, _ y: CGFloat) { out.append(.init(sprite: s, origin: CGPoint(x: x, y: y))) }
        let size = state.size, w = size.width, h = size.height, f = state.isFocused

        // The top: tiles across, the title centred over them, a corner at each end.
        var x: CGFloat = 25
        while x < w - 25 { put(PlaylistSprites.topTile(f), x, 0); x += 25 }
        put(PlaylistSprites.title(f), ((w - 100) / 2).rounded(.down), 0)
        put(PlaylistSprites.topLeft(f), 0, 0)
        put(PlaylistSprites.topRight(f), w - 25, 0)
        // The sides, down to the bottom.
        var y: CGFloat = 20
        while y < h - 38 {
            put(PlaylistSprites.leftTile, 0, y)
            put(PlaylistSprites.rightTile, w - 20, y)
            y += 29
        }
        // The bottom: tiles between the two corners.
        x = 125
        while x < w - 150 { put(PlaylistSprites.bottomTile, x, h - 38); x += 25 }
        put(PlaylistSprites.bottomLeft, 0, h - 38)
        put(PlaylistSprites.bottomRight, w - 150, h - 38)

        if state.pressed == .close { put(PlaylistSprites.closePressed, close(size).minX, close(size).minY) }
        if state.pressed == .shade { put(PlaylistSprites.shadePressed, shade(size).minX, shade(size).minY) }
        let scrolling = state.pressed == .scrollbar
        put(scrolling ? PlaylistSprites.scrollHandleSelected : PlaylistSprites.scrollHandle, w - 15,
            handleY(scroll: state.scroll, rows: state.rowCount, size: size))

        text(&out, state.runningTime, at: runningTime(size))
        text(&out, state.miniTime, at: miniTime(size))
        return out
    }

    private static func text(_ out: inout [MainWindowLayout.Placement], _ s: String, at origin: CGPoint) {
        for (i, c) in s.enumerated() {
            out.append(.init(sprite: MainSprites.character(c), origin: CGPoint(x: origin.x + CGFloat(i * 5), y: origin.y)))
        }
    }

    /// "m:ss", or "h:mm:ss" past an hour, as the running time shows totals.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension SkinRenderer {
    public static func renderPlaylistWindow(_ state: PlaylistWindowState, skin: Skin) -> CGImage? {
        render(PlaylistLayout.placements(for: state), skin: skin, size: state.size)
    }
}
