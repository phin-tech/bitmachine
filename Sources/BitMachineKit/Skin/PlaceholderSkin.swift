import CoreGraphics
import Foundation

/// BitMachine's interim Default Skin: flat, original art drawn in code, with every sheet a classic skin has, so any
/// sprite a real Skin leaves out still has something to fall back to. Real art replaces it later.
public enum PlaceholderSkin {
    public static func make() -> Skin {
        var sheets: [SpriteSheet: CGImage] = [:]
        for sheet in SpriteSheet.allCases {
            if let image = draw(sheet) { sheets[sheet] = image }
        }
        // Classic slots: 0 background, 1 grid dots, 2 (top) to 17 (bottom) bars, 18-22 oscilloscope, 23 peaks.
        var visualizer = [Palette.display, RGB(30, 34, 32)]
        visualizer += (0 ..< 16).map { i -> RGB in
            let t = Double(i) / 15
            return RGB(255, UInt8(230 - 150 * t), UInt8(120 * (1 - t)))
        }
        visualizer += (0 ..< 5).map { i in RGB(255, UInt8(176 + 15 * i), UInt8(20 * i)) }
        visualizer.append(RGB(240, 240, 240))
        return Skin(name: "BitMachine", sheets: sheets, visualizerColors: visualizer,
                    playlistColors: PlaylistColors(normal: Palette.amber, current: RGB(255, 255, 255),
                                                   normalBackground: Palette.display, selectedBackground: Palette.accent,
                                                   font: "Helvetica"),
                    regions: [:], fallback: nil)
    }

    enum Palette {
        static let body = RGB(35, 38, 45)
        static let bodyLight = RGB(58, 62, 72)
        static let bodyDark = RGB(20, 22, 26)
        static let display = RGB(10, 14, 12)
        static let amber = RGB(255, 176, 0)
        static let amberDim = RGB(90, 64, 10)
        static let accent = RGB(58, 110, 165)
        static let accentDim = RGB(44, 48, 56)
        static let button = RGB(70, 75, 86)
        static let buttonDown = RGB(45, 48, 56)
        static let glyph = RGB(220, 224, 232)
    }

    static let sizes: [SpriteSheet: (Int, Int)] = [
        .main: (275, 116), .cbuttons: (136, 36), .titlebar: (344, 87), .numbers: (99, 13), .numsEx: (108, 13),
        .playpaus: (42, 9), .monoster: (56, 24), .posbar: (307, 10), .shufrep: (92, 85), .volume: (68, 433),
        .balance: (47, 433), .text: (155, 18), .eqmain: (275, 315), .eqEx: (275, 56), .pledit: (280, 186),
        .gen: (194, 109),
    ]

    static func draw(_ sheet: SpriteSheet) -> CGImage? {
        guard let (w, h) = sizes[sheet] else { return nil }
        let c = Canvas(width: w, height: h)
        c.fill(0, 0, w, h, Palette.body)
        switch sheet {
        case .main: main(c)
        case .cbuttons: cbuttons(c)
        case .titlebar: titlebar(c)
        case .numbers, .numsEx: numbers(c, sheet == .numsEx)
        case .playpaus: playpaus(c)
        case .monoster: monoster(c)
        case .posbar: posbar(c)
        case .shufrep: shufrep(c)
        case .volume, .balance: slider(c, balance: sheet == .balance)
        case .text: text(c)
        case .eqmain: equalizer(c)
        case .eqEx: equalizerExtras(c)
        case .pledit: playlist(c)
        case .gen: c.fill(0, 0, w, h, Palette.body)
        }
        return c.image()
    }

    static func main(_ c: Canvas) {
        c.bevel(0, 0, 275, 116, light: Palette.bodyLight, dark: Palette.bodyDark)
        // The time and visualizer panel, and the title and info panel.
        c.fill(20, 22, 84, 40, Palette.display)
        c.fill(108, 22, 160, 32, Palette.display)
        c.fill(16, 72, 248, 10, Palette.bodyDark)
        c.text("kbps", 128, 43, Palette.amberDim, background: Palette.display)
        c.text("khz", 168, 43, Palette.amberDim, background: Palette.display)
        c.text("bitmachine", 222, 106, Palette.bodyLight, background: Palette.body)
    }

    static func titlebar(_ c: Canvas) {
        for (y, colour) in [(0, Palette.accent), (15, Palette.accentDim), (29, Palette.accent), (42, Palette.accentDim)] {
            c.fill(27, y, 275, 14, colour)
            c.bevel(27, y, 275, 14, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text("bitmachine", 27 + 110, y + 4, Palette.glyph, background: colour)
        }
        // Title bar buttons: options, minimize, shade (and unshade), close; the second row is pressed.
        for (x, y, glyph) in [(0, 0, "o"), (9, 0, "_"), (18, 0, "x"), (0, 18, "-"), (0, 27, "+")] {
            c.box(x, y, 9, 9, Palette.button, glyph: glyph)
            let px = y == 0 ? x : 9
            let py = y == 0 ? 9 : y
            c.box(px, py, 9, 9, Palette.buttonDown, glyph: glyph)
        }
        c.fill(304, 0, 8, 43, Palette.bodyDark)
        for (i, l) in ["o", "a", "i", "d", "v"].enumerated() {
            c.text(l, 305, 3 + i * 8, Palette.bodyLight, background: Palette.bodyDark)
        }
    }

    static func cbuttons(_ c: Canvas) {
        let widths = [23, 23, 23, 23, 22, 22]
        var x = 0
        for (i, w) in widths.enumerated() {
            let h = i == 5 ? 16 : 18
            for pressed in [false, true] {
                let y = pressed ? h : 0
                c.fill(x, y, w, h, pressed ? Palette.buttonDown : Palette.button)
                c.bevel(x, y, w, h, light: pressed ? Palette.bodyDark : Palette.bodyLight,
                        dark: pressed ? Palette.bodyLight : Palette.bodyDark)
                c.icon(i, x + w / 2, y + h / 2, Palette.glyph)
            }
            x += w
        }
    }

    static func numbers(_ c: Canvas, _ extended: Bool) {
        c.fill(0, 0, extended ? 108 : 99, 13, Palette.display)
        for d in 0 ..< 10 { c.sevenSegment(d, 9 * d, 0, Palette.amber) }
        c.fill(20, 6, 5, 1, Palette.amber)
        if extended { c.fill(100, 6, 7, 1, Palette.amber) }
    }

    static func playpaus(_ c: Canvas) {
        c.fill(0, 0, 42, 9, Palette.display)
        c.triangle(2, 1, 7, Palette.amber)
        c.fill(10, 1, 2, 7, Palette.amber); c.fill(14, 1, 2, 7, Palette.amber)
        c.fill(20, 2, 5, 5, Palette.amber)
        c.fill(36, 0, 3, 9, Palette.display)
        c.fill(40, 1, 1, 7, Palette.amber)
    }

    static func monoster(_ c: Canvas) {
        c.fill(0, 0, 56, 24, Palette.display)
        for (y, colour) in [(0, Palette.amber), (12, Palette.amberDim)] {
            c.text("stereo", 0 + 0, y + 3, colour, background: Palette.display)
            c.text("mono", 29 + 3, y + 3, colour, background: Palette.display)
        }
    }

    static func posbar(_ c: Canvas) {
        c.fill(0, 0, 248, 10, Palette.bodyDark)
        c.fill(0, 4, 248, 2, Palette.button)
        for (x, colour) in [(248, Palette.button), (278, Palette.accent)] {
            c.fill(x, 0, 29, 10, colour)
            c.bevel(x, 0, 29, 10, light: Palette.bodyLight, dark: Palette.bodyDark)
        }
    }

    static func shufrep(_ c: Canvas) {
        for (row, (on, pressed)) in [(false, false), (false, true), (true, false), (true, true)].enumerated() {
            let y = row * 15
            for (x, w, label) in [(0, 28, "rep"), (28, 47, "shuffle")] {
                c.fill(x, y, w, 15, pressed ? Palette.buttonDown : Palette.button)
                c.bevel(x, y, w, 15, light: Palette.bodyLight, dark: Palette.bodyDark)
                c.text(label, x + (w - label.count * 5) / 2, y + 5, on ? Palette.amber : Palette.glyph,
                       background: pressed ? Palette.buttonDown : Palette.button)
            }
        }
        for (x, label) in [(0, "eq"), (23, "pl"), (46, "eq"), (69, "pl")] {
            for (y, on) in [(61, false), (73, true)] {
                let pressed = x >= 46
                c.fill(x, y, 23, 12, pressed ? Palette.buttonDown : Palette.button)
                c.bevel(x, y, 23, 12, light: Palette.bodyLight, dark: Palette.bodyDark)
                c.text(label, x + 7, y + 3, on ? Palette.amber : Palette.glyph,
                       background: pressed ? Palette.buttonDown : Palette.button)
            }
        }
    }

    static func slider(_ c: Canvas, balance: Bool) {
        let x0 = balance ? 9 : 0
        let width = balance ? 38 : 68
        for frame in 0 ..< 28 {
            let y = frame * 15
            c.fill(x0, y, width, 13, Palette.bodyDark)
            c.fill(x0 + 2, y + 5, width - 4, 3, Palette.button)
            let lit = (width - 4) * frame / 27
            if balance {
                c.fill(x0 + width / 2 - lit / 2, y + 5, lit, 3, Palette.amber)
            } else {
                c.fill(x0 + 2, y + 5, lit, 3, Palette.amber)
            }
        }
        for (x, colour) in [(15, Palette.button), (0, Palette.accent)] {
            c.fill(x, 422, 14, 11, colour)
            c.bevel(x, 422, 14, 11, light: Palette.bodyLight, dark: Palette.bodyDark)
        }
    }

    static func equalizer(_ c: Canvas) {
        // The window: a bevelled body, the graph's frame, and labels for the sliders.
        c.bevel(0, 0, 275, 116, light: Palette.bodyLight, dark: Palette.bodyDark)
        c.fill(84, 15, 117, 23, Palette.bodyDark)
        c.text("preamp", 13, 104, Palette.bodyLight, background: Palette.body)
        for (i, label) in ["60", "170", "310", "600", "1k", "3k", "6k", "12k", "14k", "16k"].enumerated() {
            c.text(label, 78 + 18 * i + 7 - label.count * 5 / 2, 104, Palette.bodyLight, background: Palette.body)
        }
        c.text("+12", 47, 37, Palette.bodyLight, background: Palette.body)
        c.text("0", 57, 66, Palette.bodyLight, background: Palette.body)
        c.text("-12", 47, 95, Palette.bodyLight, background: Palette.body)
        // Title bars: focused, then not.
        for (y, colour) in [(134, Palette.accent), (149, Palette.accentDim)] {
            c.fill(0, y, 275, 14, colour)
            c.bevel(0, y, 275, 14, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text("equalizer", 115, y + 4, Palette.glyph, background: colour)
            c.box(254, y + 3, 9, 9, Palette.button, glyph: "-")
            c.box(264, y + 3, 9, 9, Palette.button, glyph: "x")
        }
        c.box(0, 116, 9, 9, Palette.button, glyph: "x")
        c.box(0, 125, 9, 9, Palette.buttonDown, glyph: "x")
        // ON and AUTO: off, off pressed, on, on pressed.
        for (x, label, on, pressed) in [(10, "on", false, false), (128, "on", false, true), (69, "on", true, false),
                                        (187, "on", true, true), (36, "auto", false, false),
                                        (154, "auto", false, true), (95, "auto", true, false), (213, "auto", true, true)] {
            let w = label == "on" ? 26 : 32
            let face = pressed ? Palette.buttonDown : Palette.button
            c.fill(x, 119, w, 12, face)
            c.bevel(x, 119, w, 12, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text(label, x + (w - label.count * 5) / 2, 122, on ? Palette.amber : Palette.glyph, background: face)
        }
        // The slider backgrounds: 28 frames from -12 dB to +12 dB, lit from the middle.
        for frame in 0 ..< 28 {
            let x = 13 + (frame % 14) * 15, y = 164 + (frame / 14) * 65
            c.fill(x, y, 14, 63, Palette.bodyDark)
            c.fill(x + 6, y + 1, 2, 61, Palette.button)
            let level = (frame - 14) * 30 / 14
            if level > 0 { c.fill(x + 6, y + 31 - level, 2, level, Palette.amber) }
            if level < 0 { c.fill(x + 6, y + 31, 2, -level, Palette.amberDim) }
        }
        for (y, colour) in [(164, Palette.button), (176, Palette.accent)] {
            c.fill(0, y, 11, 11, colour)
            c.bevel(0, y, 11, 11, light: Palette.bodyLight, dark: Palette.bodyDark)
        }
        for (y, face) in [(164, Palette.button), (176, Palette.buttonDown)] {
            c.fill(224, y, 44, 12, face)
            c.bevel(224, y, 44, 12, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text("presets", 229, y + 3, Palette.glyph, background: face)
        }
        // The graph, its line colours (top to bottom) and the preamp line.
        c.fill(0, 294, 113, 19, Palette.display)
        c.fill(0, 303, 113, 1, RGB(30, 34, 32))
        for row in 0 ..< 19 {
            let t = Double(row) / 18
            c.fill(115, 294 + row, 1, 1, RGB(255, UInt8(230 - 120 * t), UInt8(140 * (1 - t))))
        }
        c.fill(0, 314, 113, 1, Palette.amberDim)
    }

    static func equalizerExtras(_ c: Canvas) {
        for (y, colour) in [(0, Palette.accent), (15, Palette.accentDim)] {
            c.fill(0, y, 275, 14, colour)
            c.bevel(0, y, 275, 14, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text("equalizer", 115, y + 4, Palette.glyph, background: colour)
        }
        c.box(1, 38, 9, 9, Palette.buttonDown, glyph: "-")
        c.box(1, 47, 9, 9, Palette.buttonDown, glyph: "+")
        c.box(11, 38, 9, 9, Palette.button, glyph: "x")
        c.box(11, 47, 9, 9, Palette.buttonDown, glyph: "x")
    }

    static func playlist(_ c: Canvas) {
        // Title bar pieces, focused (y 0) and not (y 21): left corner, title, tile, right corner.
        for (y, colour) in [(0, Palette.accent), (21, Palette.accentDim)] {
            for (x, w) in [(0, 25), (26, 100), (127, 25), (153, 25)] {
                c.fill(x, y, w, 20, Palette.body)
                c.fill(x, y + 4, w, 12, colour)
                c.fill(x, y, w, 1, Palette.bodyLight)
                c.fill(x, y + 19, w, 1, Palette.bodyDark)
            }
            c.fill(0, y, 1, 20, Palette.bodyLight)
            c.fill(177, y, 1, 20, Palette.bodyDark)
            c.text("playlist", 26 + 30, y + 7, Palette.glyph, background: colour)
            c.box(153 + 4, y + 3, 9, 9, Palette.button, glyph: "-")
            c.box(153 + 14, y + 3, 9, 9, Palette.button, glyph: "x")
        }
        // The sides: the left edge, and the right edge with the scroll track.
        c.fill(0, 42, 12, 29, Palette.body)
        c.fill(0, 42, 1, 29, Palette.bodyLight)
        c.fill(31, 42, 20, 29, Palette.body)
        c.fill(36, 42, 8, 29, Palette.bodyDark)
        c.fill(50, 42, 1, 29, Palette.bodyDark)
        for (x, colour) in [(52, Palette.button), (61, Palette.accent)] {
            c.fill(x, 53, 8, 18, colour)
            c.bevel(x, 53, 8, 18, light: Palette.bodyLight, dark: Palette.bodyDark)
        }
        c.box(52, 42, 9, 9, Palette.buttonDown, glyph: "x")
        c.box(62, 42, 9, 9, Palette.buttonDown, glyph: "-")
        // The bottom: a tile, the left corner with ADD REM SEL MISC, the right corner with LIST, the mini transport
        // and the time display.
        c.fill(179, 0, 25, 38, Palette.body)
        c.fill(179, 37, 25, 1, Palette.bodyDark)
        c.fill(0, 72, 125, 38, Palette.body)
        c.fill(0, 72, 1, 38, Palette.bodyLight)
        c.fill(0, 109, 125, 1, Palette.bodyDark)
        for (x, label) in [(14, "add"), (43, "rem"), (72, "sel"), (101, "misc")] {
            c.fill(x, 80, 22, 18, Palette.button)
            c.bevel(x, 80, 22, 18, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.text(label, x + max((22 - label.count * 5) / 2, 0) + (label.count < 4 ? 1 : 0), 86, Palette.glyph,
                   background: Palette.button)
        }
        c.fill(126, 72, 150, 38, Palette.body)
        c.fill(126, 109, 150, 1, Palette.bodyDark)
        c.fill(275, 72, 1, 38, Palette.bodyDark)
        c.fill(126 + 106, 80, 22, 18, Palette.button)
        c.bevel(126 + 106, 80, 22, 18, light: Palette.bodyLight, dark: Palette.bodyDark)
        c.text("list", 126 + 106 + 1, 86, Palette.glyph, background: Palette.button)
        c.fill(126 + 5, 72 + 8, 92, 10, Palette.display)
        c.fill(126 + 64, 72 + 21, 30, 10, Palette.display)
        for i in 0 ..< 6 {
            let x = 126 + 3 + i * 10, y = 72 + 22
            c.fill(x, y, 10, 10, Palette.button)
            c.bevel(x, y, 10, 10, light: Palette.bodyLight, dark: Palette.bodyDark)
            c.miniIcon(i, x + 5, y + 5, Palette.glyph)
        }
        // The resize grip.
        for d in 0 ..< 3 { c.fill(126 + 140 + d * 3, 72 + 34 - d * 3, 2, 2 + d * 3, Palette.bodyLight) }
    }

    static func text(_ c: Canvas) {
        c.fill(0, 0, 155, 18, Palette.display)
        for (char, (row, column)) in MainSprites.textFont {
            c.glyph(char, column * 5 + 1, row * 6, Palette.amber)
        }
    }
}

/// A bitmap drawn with the origin at the top left, in whole pixels.
final class Canvas {
    let width, height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
    }

    func image() -> CGImage? { context.makeImage() }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ colour: RGB) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(colour.cgColor)
        context.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    func bevel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, light: RGB, dark: RGB) {
        fill(x, y, w, 1, light); fill(x, y, 1, h, light)
        fill(x, y + h - 1, w, 1, dark); fill(x + w - 1, y, 1, h, dark)
    }

    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ colour: RGB, glyph: String) {
        fill(x, y, w, h, colour)
        bevel(x, y, w, h, light: PlaceholderSkin.Palette.bodyLight, dark: PlaceholderSkin.Palette.bodyDark)
        text(glyph, x + 3, y + 2, PlaceholderSkin.Palette.glyph, background: nil)
    }

    func text(_ s: String, _ x: Int, _ y: Int, _ colour: RGB, background: RGB?) {
        for (i, ch) in s.enumerated() {
            if let background { fill(x + i * 5, y, 5, 6, background) }
            glyph(ch, x + i * 5 + 1, y, colour)
        }
    }

    func glyph(_ ch: Character, _ x: Int, _ y: Int, _ colour: RGB) {
        guard let rows = PixelFont.glyphs[Character(ch.lowercased())] else { return }
        for (dy, row) in rows.enumerated() {
            for (dx, bit) in row.enumerated() where bit == "1" { fill(x + dx, y + dy, 1, 1, colour) }
        }
    }

    /// A seven-segment digit in a 9×13 cell.
    func sevenSegment(_ d: Int, _ x: Int, _ y: Int, _ colour: RGB) {
        let segments = ["1111110", "0110000", "1101101", "1111001", "0110011", "1011011", "1011111", "1110000",
                        "1111111", "1111011"][d]
        let on = segments.map { $0 == "1" }
        if on[0] { fill(x + 2, y + 1, 5, 1, colour) }
        if on[1] { fill(x + 7, y + 2, 1, 4, colour) }
        if on[2] { fill(x + 7, y + 7, 1, 4, colour) }
        if on[3] { fill(x + 2, y + 11, 5, 1, colour) }
        if on[4] { fill(x + 1, y + 7, 1, 4, colour) }
        if on[5] { fill(x + 1, y + 2, 1, 4, colour) }
        if on[6] { fill(x + 2, y + 6, 5, 1, colour) }
    }

    func triangle(_ x: Int, _ y: Int, _ size: Int, _ colour: RGB) {
        for i in 0 ..< (size + 1) / 2 { fill(x + i, y + i, 1, size - 2 * i, colour) }
    }

    /// The transport icons: previous, play, pause, stop, next, eject, centred on (cx, cy).
    func icon(_ i: Int, _ cx: Int, _ cy: Int, _ colour: RGB) {
        switch i {
        case 0: fill(cx - 5, cy - 4, 2, 9, colour); leftTriangle(cx - 3, cy, colour); leftTriangle(cx + 2, cy, colour)
        case 1: triangle(cx - 2, cy - 4, 9, colour)
        case 2: fill(cx - 4, cy - 4, 3, 9, colour); fill(cx + 1, cy - 4, 3, 9, colour)
        case 3: fill(cx - 4, cy - 4, 8, 8, colour)
        case 4: triangle(cx - 6, cy - 4, 9, colour); triangle(cx - 1, cy - 4, 9, colour); fill(cx + 4, cy - 4, 2, 9, colour)
        default:
            for r in 0 ..< 4 { fill(cx - r, cy - 4 + r, 2 * r + 1, 1, colour) }
            fill(cx - 4, cy + 2, 9, 2, colour)
        }
    }

    /// The mini transport's icons, 5 pixels across, centred on (cx, cy).
    func miniIcon(_ i: Int, _ cx: Int, _ cy: Int, _ colour: RGB) {
        switch i {
        case 0: fill(cx - 2, cy - 2, 1, 5, colour); for k in 0 ..< 3 { fill(cx + 1 - k, cy - k, 1, 2 * k + 1, colour) }
        case 1: for k in 0 ..< 3 { fill(cx - 1 + k, cy - 2 + k, 1, 5 - 2 * k, colour) }
        case 2: fill(cx - 2, cy - 2, 2, 5, colour); fill(cx + 1, cy - 2, 2, 5, colour)
        case 3: fill(cx - 2, cy - 2, 5, 5, colour)
        case 4: for k in 0 ..< 3 { fill(cx - 2 + k, cy - 2 + k, 1, 5 - 2 * k, colour) }; fill(cx + 2, cy - 2, 1, 5, colour)
        default: for k in 0 ..< 3 { fill(cx - k, cy - 2 + k, 2 * k + 1, 1, colour) }; fill(cx - 2, cy + 2, 5, 1, colour)
        }
    }

    private func leftTriangle(_ tipX: Int, _ cy: Int, _ colour: RGB) {
        for i in 0 ..< 5 { fill(tipX + i, cy - i, 1, 2 * i + 1, colour) }
    }
}

/// A 3×5 pixel font, original to BitMachine, for the placeholder Skin.
enum PixelFont {
    static let glyphs: [Character: [String]] = [
        "a": ["010", "101", "111", "101", "101"], "b": ["110", "101", "110", "101", "110"],
        "c": ["011", "100", "100", "100", "011"], "d": ["110", "101", "101", "101", "110"],
        "e": ["111", "100", "110", "100", "111"], "f": ["111", "100", "110", "100", "100"],
        "g": ["011", "100", "101", "101", "011"], "h": ["101", "101", "111", "101", "101"],
        "i": ["111", "010", "010", "010", "111"], "j": ["001", "001", "001", "101", "010"],
        "k": ["101", "101", "110", "101", "101"], "l": ["100", "100", "100", "100", "111"],
        "m": ["101", "111", "111", "101", "101"], "n": ["110", "101", "101", "101", "101"],
        "o": ["010", "101", "101", "101", "010"], "p": ["110", "101", "110", "100", "100"],
        "q": ["010", "101", "101", "110", "011"], "r": ["110", "101", "110", "101", "101"],
        "s": ["011", "100", "010", "001", "110"], "t": ["111", "010", "010", "010", "010"],
        "u": ["101", "101", "101", "101", "111"], "v": ["101", "101", "101", "101", "010"],
        "w": ["101", "101", "111", "111", "101"], "x": ["101", "101", "010", "101", "101"],
        "y": ["101", "101", "010", "010", "010"], "z": ["111", "001", "010", "100", "111"],
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["110", "001", "010", "100", "111"], "3": ["110", "001", "010", "001", "110"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "110", "001", "110"],
        "6": ["011", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "110"],
        ".": ["000", "000", "000", "000", "010"], ":": ["000", "010", "000", "010", "000"],
        "-": ["000", "000", "111", "000", "000"], "(": ["001", "010", "010", "010", "001"],
        ")": ["100", "010", "010", "010", "100"], "'": ["010", "010", "000", "000", "000"],
        "!": ["010", "010", "010", "000", "010"], "_": ["000", "000", "000", "000", "111"],
        "/": ["001", "001", "010", "100", "100"], ",": ["000", "000", "000", "010", "100"],
        "+": ["000", "010", "111", "010", "000"], "?": ["110", "001", "010", "000", "010"],
        "&": ["010", "101", "010", "101", "011"], "…": ["000", "000", "000", "000", "101"],
        "\"": ["101", "101", "000", "000", "000"], "=": ["000", "111", "000", "111", "000"],
        "[": ["110", "100", "100", "100", "110"], "]": ["011", "001", "001", "001", "011"],
        "*": ["000", "101", "010", "101", "000"],
    ]
}
