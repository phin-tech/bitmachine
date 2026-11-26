import CoreGraphics
import CoreText
import Foundation

// The generic window's sprites and layout follow Webamp's skinSprites.ts, skinParser.js (the title letters) and
// css/gen-window.css (MIT; see THIRD_PARTY_NOTICES.md).

/// What the Radio Window shows.
public struct RadioWindowState: Equatable, Sendable {
    public var stations: [Station] = []
    public var selected: Int?
    /// The first row showing.
    public var scroll = 0
    /// What the list is ("Most played", "12 stations for jazz", "Searching…", an error).
    public var status = ""
    public var presets = RadioPresets()
    /// The Station playing, if one is.
    public var playing: URL?
    public var isFocused = true
    public var pressed: RadioControl?

    public init() {}

    public var maxScroll: Int { max(stations.count - RadioWindowLayout.visibleRows, 0) }
}

public enum RadioControl: Hashable, Sendable {
    case titleBar, close, top, search
    case row(Int)
    case preset(Int)
}

/// The generic window's sprites (`gen.bmp`), which classic skins use for windows beyond the main three.
public enum GenSprites {
    public static func topLeft(_ on: Bool) -> Sprite { Sprite(.gen, 0, on ? 0 : 21, 25, 20) }
    public static func topLeftEnd(_ on: Bool) -> Sprite { Sprite(.gen, 26, on ? 0 : 21, 25, 20) }
    public static func topCenterFill(_ on: Bool) -> Sprite { Sprite(.gen, 52, on ? 0 : 21, 25, 20) }
    public static func topRightEnd(_ on: Bool) -> Sprite { Sprite(.gen, 78, on ? 0 : 21, 25, 20) }
    public static func topLeftRightFill(_ on: Bool) -> Sprite { Sprite(.gen, 104, on ? 0 : 21, 25, 20) }
    public static func topRight(_ on: Bool) -> Sprite { Sprite(.gen, 130, on ? 0 : 21, 25, 20) }
    public static let bottomLeft = Sprite(.gen, 0, 42, 125, 14)
    public static let bottomRight = Sprite(.gen, 0, 57, 125, 14)
    public static let bottomFill = Sprite(.gen, 127, 72, 25, 14)
    public static let middleLeft = Sprite(.gen, 127, 42, 11, 29)
    public static let middleLeftBottom = Sprite(.gen, 158, 42, 11, 24)
    public static let middleRight = Sprite(.gen, 139, 42, 8, 29)
    public static let middleRightBottom = Sprite(.gen, 170, 42, 8, 24)
    public static let closePressed = Sprite(.gen, 148, 42, 9, 9)

    /// The title font: A to Z in a row at y 88 (focused) and 96, each letter as wide as it is drawn, with a pixel of
    /// the row's first colour between letters. Widths differ from Skin to Skin, so they're measured.
    public static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func measureLetters(in sheet: CGImage, selected: Bool) -> [Character: Sprite] {
        let y = selected ? 88 : 96
        guard sheet.height >= y + 7, let row = pixelRow(of: sheet, y: y) else { return [:] }
        let background = row[0]
        var out: [Character: Sprite] = [:]
        var x = 1
        for letter in letters {
            var end = x
            while end < row.count, row[end] != background { end += 1 }
            if end > x { out[letter] = Sprite(.gen, x, y, end - x, 7) }
            x = end + 1
            if x >= row.count { break }
        }
        return out
    }

    /// One row of a bitmap's pixels, as RGBA words.
    static func pixelRow(of image: CGImage, y: Int) -> [UInt32]? {
        let width = image.width
        var row = [UInt32](repeating: 0, count: width)
        let made = row.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Draw the image so that row `y` (from the top) lands in this one-pixel-high context.
            context.draw(image, in: CGRect(x: 0, y: -(image.height - 1 - y), width: width, height: image.height))
            return true
        }
        return made ? row : nil
    }
}

/// Where everything goes on the Radio Window, in skin pixels from the top left.
public enum RadioWindowLayout {
    public static let size = CGSize(width: 275, height: 232)
    public static let title = "RADIO"
    public static let close = CGRect(x: 264, y: 3, width: 9, height: 9)
    public static let content = CGRect(x: 11, y: 20, width: 256, height: 198)

    /// Where BitMachine puts a real text field for the search.
    public static let search = CGRect(x: 14, y: 23, width: 206, height: 13)
    public static let top = CGRect(x: 224, y: 23, width: 40, height: 13)
    public static let list = CGRect(x: 14, y: 39, width: 250, height: 144)
    public static let rowHeight: CGFloat = 12
    public static var visibleRows: Int { Int(list.height / rowHeight) }
    public static let status = CGRect(x: 14, y: 184, width: 250, height: 11)

    public static func preset(_ i: Int) -> CGRect {
        CGRect(x: 14 + CGFloat(i) * 42, y: 198, width: 40, height: 16)
    }

    public static func control(at p: CGPoint, state: RadioWindowState) -> RadioControl? {
        if close.contains(p) { return .close }
        if p.y < 14 { return .titleBar }
        if search.contains(p) { return .search }
        if top.contains(p) { return .top }
        if list.contains(p) {
            let row = state.scroll + Int((p.y - list.minY) / rowHeight)
            return row < state.stations.count ? .row(row) : nil
        }
        for i in 0 ..< RadioPresets.count where preset(i).contains(p) { return .preset(i) }
        return nil
    }

    // MARK: The frame

    /// The frame's sprites, back to front: the title bar with the title in the middle, the sides and the bottom.
    public static func placements(focused: Bool, closePressed: Bool, letterWidth: (Character) -> Int)
        -> [MainWindowLayout.Placement] {
        var out: [MainWindowLayout.Placement] = []
        func put(_ s: Sprite, _ x: CGFloat, _ y: CGFloat) { out.append(.init(sprite: s, origin: CGPoint(x: x, y: y))) }
        func tile(_ s: Sprite, from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
            var x = x0
            while x < x1 { put(s, x, y); x += s.rect.width }
        }
        func tileDown(_ s: Sprite, x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
            var y = y0
            while y < y1 { put(s, x, y); y += s.rect.height }
        }
        let w = size.width, h = size.height
        let titleWidth = CGFloat(title.reduce(0) { $0 + ($1 == " " ? 5 : letterWidth($1)) })
        // Four pixels before the letters and three after, as in classic players.
        let titleX = ((w - titleWidth - 7) / 2).rounded(.down)

        tile(GenSprites.topCenterFill(focused), from: 0, to: w, y: 0)
        tile(GenSprites.topLeftRightFill(focused), from: 25, to: titleX - 25, y: 0)
        tile(GenSprites.topLeftRightFill(focused), from: titleX + titleWidth + 7 + 25, to: w - 25, y: 0)
        put(GenSprites.topLeftEnd(focused), titleX - 25, 0)
        put(GenSprites.topRightEnd(focused), titleX + titleWidth + 7, 0)
        put(GenSprites.topLeft(focused), 0, 0)
        put(GenSprites.topRight(focused), w - 25, 0)
        if closePressed { put(GenSprites.closePressed, close.minX, close.minY) }

        tileDown(GenSprites.middleLeft, x: 0, from: 20, to: h - 14)
        tileDown(GenSprites.middleRight, x: w - 8, from: 20, to: h - 14)
        put(GenSprites.middleLeftBottom, 0, h - 14 - 24)
        put(GenSprites.middleRightBottom, w - 8, h - 14 - 24)
        tile(GenSprites.bottomFill, from: 0, to: w, y: h - 14)
        put(GenSprites.bottomLeft, 0, h - 14)
        put(GenSprites.bottomRight, w - 125, h - 14)
        return out
    }

    /// Where the title's letters start, given their widths.
    static func titleLetters(letterWidth: (Character) -> Int) -> [(Character, CGFloat)] {
        let titleWidth = CGFloat(title.reduce(0) { $0 + ($1 == " " ? 5 : letterWidth($1)) })
        var x = ((size.width - titleWidth - 7) / 2).rounded(.down) + 4
        var out: [(Character, CGFloat)] = []
        for c in title {
            if c != " " { out.append((c, x)) }
            x += CGFloat(c == " " ? 5 : letterWidth(c))
        }
        return out
    }
}

extension Skin {
    /// The title letters of `gen.bmp`, measured; from the fallback when this Skin has no `gen.bmp`.
    func genLetters(selected: Bool) -> [Character: Sprite] {
        let key = selected ? "selected" : "plain"
        lock.lock()
        if let cached = letterCache[key] { lock.unlock(); return cached }
        lock.unlock()
        var letters: [Character: Sprite] = [:]
        if let sheet = ownSheet(.gen) { letters = GenSprites.measureLetters(in: sheet, selected: selected) }
        if letters.isEmpty, let fallback { letters = fallback.genLetters(selected: selected) }
        lock.lock(); letterCache[key] = letters; lock.unlock()
        return letters
    }
}

extension SkinRenderer {
    /// Draws the Radio Window `scale` image pixels to a skin pixel: the Skin's art stays pixel for pixel, and the text
    /// is drawn at the full resolution, so it's sharp on a Retina screen and at Double Size.
    public static func renderRadioWindow(_ state: RadioWindowState, skin: Skin, scale: CGFloat = 1) -> CGImage? {
        let size = RadioWindowLayout.size
        let letters = skin.genLetters(selected: state.isFocused)
        let width = { (c: Character) in Int(letters[c]?.rect.width ?? 5) }
        var placements = RadioWindowLayout.placements(focused: state.isFocused, closePressed: state.pressed == .close,
                                                      letterWidth: width)
        for (c, x) in RadioWindowLayout.titleLetters(letterWidth: width) {
            if let sprite = letters[c] { placements.append(.init(sprite: sprite, origin: CGPoint(x: x, y: 2))) }
        }
        let scale = max(scale.rounded(), 1)
        guard let frame = render(placements, skin: skin, size: size),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.scaleBy(x: scale, y: scale)
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        RadioContent(context: context, height: size.height, colors: skin.playlistColors).draw(state)
        return context.makeImage()
    }
}

/// The Radio Window's insides, in the Skin's Playlist colours and font: the station list, the TOP button, the
/// status line and the six presets.
struct RadioContent {
    let context: CGContext
    let height: CGFloat
    let colors: PlaylistColors

    private var font: CTFont {
        let named = CTFontCreateWithName(colors.font as CFString, 9, nil)
        // A Skin can name a Windows font the Mac doesn't have; Core Text then substitutes, which is fine.
        return named
    }

    func draw(_ state: RadioWindowState) {
        fill(RadioWindowLayout.content, colors.normalBackground)

        // The search field is a real text field on top; this is its well.
        outline(RadioWindowLayout.search, colors.normal.dimmed)
        button(RadioWindowLayout.top, "TOP", pressed: state.pressed == .top, lit: false)

        let list = RadioWindowLayout.list
        let rows = RadioWindowLayout.visibleRows
        for line in 0 ..< rows {
            let i = state.scroll + line
            guard i < state.stations.count else { break }
            let station = state.stations[i]
            let rect = CGRect(x: list.minX, y: list.minY + CGFloat(line) * RadioWindowLayout.rowHeight,
                              width: list.width, height: RadioWindowLayout.rowHeight)
            if state.selected == i { fill(rect, colors.selectedBackground) }
            let colour = station.url == state.playing ? colors.current : colors.normal
            let info = [station.codec, station.bitrate > 0 ? String(station.bitrate) : ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            text(station.frequency.description, in: CGRect(x: rect.minX, y: rect.minY, width: 24, height: rect.height),
                 colour, alignment: .right)
            let infoWidth: CGFloat = 46
            text(station.name, in: CGRect(x: rect.minX + 30, y: rect.minY, width: rect.width - 30 - infoWidth - 4,
                                          height: rect.height), colour)
            text(info, in: CGRect(x: rect.maxX - infoWidth, y: rect.minY, width: infoWidth, height: rect.height),
                 colour.dimmed, alignment: .right)
        }
        if state.stations.count > rows {
            // A thin scroll indicator down the right edge of the list.
            let track = CGRect(x: list.maxX + 1, y: list.minY, width: 1, height: list.height)
            fill(track, colors.normal.dimmed)
            let fraction = CGFloat(rows) / CGFloat(state.stations.count)
            let offset = CGFloat(state.scroll) / CGFloat(max(state.stations.count - rows, 1)) * (1 - fraction)
            fill(CGRect(x: track.minX, y: track.minY + offset * track.height, width: 1,
                        height: max(fraction * track.height, 4)), colors.normal)
        }

        text(state.status, in: RadioWindowLayout.status, colors.normal.dimmed)

        for i in 0 ..< RadioPresets.count {
            let station = state.presets[i]
            let name = station.map { " " + $0.name } ?? ""
            button(RadioWindowLayout.preset(i), "\(i + 1)\(name)", pressed: state.pressed == .preset(i),
                   lit: station != nil && station?.url == state.playing)
        }
    }

    // MARK: Drawing, from the top left

    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

    private func fill(_ r: CGRect, _ colour: RGB) {
        context.setFillColor(colour.cgColor)
        context.fill(flip(r))
    }

    private func outline(_ r: CGRect, _ colour: RGB) {
        fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1), colour)
        fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), colour)
        fill(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height), colour)
        fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), colour)
    }

    private func button(_ r: CGRect, _ label: String, pressed: Bool, lit: Bool) {
        if pressed || lit { fill(r, colors.selectedBackground) }
        outline(r, lit ? colors.current : colors.normal.dimmed)
        text(label, in: r.insetBy(dx: 3, dy: 0), lit ? colors.current : colors.normal, alignment: .center)
    }

    private func text(_ string: String, in r: CGRect, _ colour: RGB, alignment: CTTextAlignment = .left) {
        guard !string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour.cgColor,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(r.width) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(r.width), .end, ellipsis) ?? line
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var x = r.minX
        if alignment == .right { x = r.maxX - width } else if alignment == .center { x = r.midX - width / 2 }
        // The baseline sits so the text is centred in the box.
        let baseline = r.minY + (r.height + CTFontGetCapHeight(font)) / 2
        context.saveGState()
        context.clip(to: flip(r))
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: x.rounded(), y: (height - baseline).rounded())
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension RGB {
    /// A quarter of the way to black, for secondary text and outlines.
    var dimmed: RGB { RGB(r / 2 + r / 4, g / 2 + g / 4, b / 2 + b / 4) }
}
