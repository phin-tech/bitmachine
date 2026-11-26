import CoreGraphics
import Foundation

// Sprite coordinates and positions follow Webamp's skinSprites.ts and css/equalizer-window.css (MIT; see
// THIRD_PARTY_NOTICES.md).

/// What the equalizer does to the sound, saved between launches.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    public var on = false
    /// Classic players chose a preset per Track with this; BitMachine keeps the switch for now.
    public var auto = false
    /// dB, -12...12
    public var preamp: Double = 0
    /// dB, -12...12, one per band in `AudioOutput.bands`.
    public var gains: [Double] = Array(repeating: 0, count: 10)

    public init() {}

    public static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 2, 4, 6, 7, 7]),
        ("Loudness", [6, 4, 1, 0, -1, 0, 1, 4, 5, 5]),
        ("Vocal", [-3, -2, 0, 3, 5, 5, 3, 0, -2, -3]),
        ("Late Night", [-4, -2, 0, 1, 2, 2, 1, 0, -2, -4]),
    ]
}

/// What the Equalizer Window shows.
public struct EqualizerWindowState: Equatable, Sendable {
    public var settings = EqualizerSettings()
    public var isFocused = true
    public var isWindowshade = false
    public var pressed: EqualizerControl?
    public init() {}
}

public enum EqualizerControl: Hashable, Sendable {
    case titleBar, close, shade, on, auto, presets, preamp
    case band(Int)
}

public enum EqualizerSprites {
    public static let background = Sprite(.eqmain, 0, 0, 275, 116)
    public static let titleBar = Sprite(.eqmain, 0, 149, 275, 14)
    public static let titleBarSelected = Sprite(.eqmain, 0, 134, 275, 14)
    public static let closeButton = Sprite(.eqmain, 0, 116, 9, 9)
    public static let closeButtonPressed = Sprite(.eqmain, 0, 125, 9, 9)
    public static let shadeButtonPressed = Sprite(.eqEx, 1, 38, 9, 9)
    public static let thumb = Sprite(.eqmain, 0, 164, 11, 11)
    public static let thumbSelected = Sprite(.eqmain, 0, 176, 11, 11)
    public static let graphBackground = Sprite(.eqmain, 0, 294, 113, 19)
    public static let graphLineColors = Sprite(.eqmain, 115, 294, 1, 19)
    public static let preampLine = Sprite(.eqmain, 0, 314, 113, 1)
    public static let shadeBackground = Sprite(.eqEx, 0, 15, 275, 14)
    public static let shadeBackgroundSelected = Sprite(.eqEx, 0, 0, 275, 14)
    public static let shadeCloseButton = Sprite(.eqEx, 11, 38, 9, 9)
    public static let shadeCloseButtonPressed = Sprite(.eqEx, 11, 47, 9, 9)
    public static let unshadeButtonPressed = Sprite(.eqEx, 1, 47, 9, 9)

    /// The slider's background for a value: 28 frames, 14 to a row, 15 pixels apart across and 65 down.
    public static func sliderBackground(frame: Int) -> Sprite {
        let f = min(max(frame, 0), 27)
        return Sprite(.eqmain, 13 + (f % 14) * 15, 164 + (f / 14) * 65, 14, 63)
    }

    public static func onButton(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.eqmain, [10, 128, 69, 187][(on ? 2 : 0) + (pressed ? 1 : 0)], 119, 26, 12)
    }

    public static func autoButton(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.eqmain, [36, 154, 95, 213][(on ? 2 : 0) + (pressed ? 1 : 0)], 119, 32, 12)
    }

    public static func presetsButton(pressed: Bool) -> Sprite { Sprite(.eqmain, 224, pressed ? 176 : 164, 44, 12) }
}

public enum EqualizerLayout {
    public static let size = CGSize(width: 275, height: 116)
    public static let shadeSize = CGSize(width: 275, height: 14)
    public static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    public static let close = CGRect(x: 264, y: 3, width: 9, height: 9)
    public static let shade = CGRect(x: 254, y: 3, width: 9, height: 9)
    public static let on = CGRect(x: 14, y: 18, width: 26, height: 12)
    public static let auto = CGRect(x: 40, y: 18, width: 32, height: 12)
    public static let presets = CGRect(x: 217, y: 18, width: 44, height: 12)
    public static let graph = CGRect(x: 86, y: 17, width: 113, height: 19)
    public static let preamp = CGRect(x: 21, y: 38, width: 14, height: 63)

    public static func band(_ i: Int) -> CGRect { CGRect(x: 78 + 18 * i, y: 38, width: 14, height: 63) }

    /// How far a thumb travels: the 62-pixel slot less the 11-pixel thumb.
    static let travel: CGFloat = 51

    public static func control(at p: CGPoint, windowshade: Bool) -> EqualizerControl? {
        if close.contains(p) { return .close }
        if shade.contains(p) { return .shade }
        if windowshade { return CGRect(origin: .zero, size: shadeSize).contains(p) ? .titleBar : nil }
        if on.contains(p) { return .on }
        if auto.contains(p) { return .auto }
        if presets.contains(p) { return .presets }
        if preamp.contains(p) { return .preamp }
        if let i = (0 ..< 10).first(where: { band($0).contains(p) }) { return .band(i) }
        if titleBar.contains(p) { return .titleBar }
        return nil
    }

    /// The gain a click or drag at `y` sets, centring the thumb under the mouse; it snaps to 0 dB near the middle.
    public static func gain(atY y: CGFloat) -> Double {
        let fraction = 1 - min(max((y - preamp.minY - 5.5) / travel, 0), 1)
        let db = Double(fraction) * 24 - 12
        return abs(db) < 0.75 ? 0 : (db * 10).rounded() / 10
    }

    static func thumbY(_ db: Double) -> CGFloat {
        preamp.minY + 1 + (travel * CGFloat(1 - (min(max(db, -12), 12) + 12) / 24)).rounded()
    }

    static func frame(_ db: Double) -> Int { Int(((min(max(db, -12), 12) + 12) / 24 * 27).rounded()) }

    public static func placements(for state: EqualizerWindowState) -> [MainWindowLayout.Placement] {
        var out: [MainWindowLayout.Placement] = []
        func put(_ s: Sprite, _ x: CGFloat, _ y: CGFloat) { out.append(.init(sprite: s, origin: CGPoint(x: x, y: y))) }
        let held = state.pressed
        let s = state.settings

        if state.isWindowshade {
            put(state.isFocused ? EqualizerSprites.shadeBackgroundSelected : EqualizerSprites.shadeBackground, 0, 0)
            if held == .shade { put(EqualizerSprites.unshadeButtonPressed, shade.minX, shade.minY) }
            put(held == .close ? EqualizerSprites.shadeCloseButtonPressed : EqualizerSprites.shadeCloseButton,
                close.minX, close.minY)
            return out
        }

        put(EqualizerSprites.background, 0, 0)
        put(state.isFocused ? EqualizerSprites.titleBarSelected : EqualizerSprites.titleBar, 0, 0)
        if held == .shade { put(EqualizerSprites.shadeButtonPressed, shade.minX, shade.minY) }
        if held == .close { put(EqualizerSprites.closeButtonPressed, close.minX, close.minY) }
        put(EqualizerSprites.onButton(on: s.on, pressed: held == .on), on.minX, on.minY)
        put(EqualizerSprites.autoButton(on: s.auto, pressed: held == .auto), auto.minX, auto.minY)
        put(EqualizerSprites.presetsButton(pressed: held == .presets), presets.minX, presets.minY)
        put(EqualizerSprites.graphBackground, graph.minX, graph.minY)

        let sliders: [(CGRect, Double, EqualizerControl)] = [(preamp, s.preamp, .preamp)]
            + (0 ..< 10).map { (band($0), s.gains[$0], .band($0)) }
        for (rect, db, control) in sliders {
            put(EqualizerSprites.sliderBackground(frame: frame(db)), rect.minX, rect.minY)
            put(held == control ? EqualizerSprites.thumbSelected : EqualizerSprites.thumb, rect.minX + 1, thumbY(db))
        }
        return out
    }

    /// The curve through the ten bands, one y (0 at the top, 18 at the bottom) for each of the graph's columns from
    /// 2 to 110: a natural cubic spline, as classic players drew it.
    public static func curve(_ gains: [Double]) -> [Int] {
        let xs = (0 ..< 10).map { Double($0 * 12) }
        let ys = gains.map { (12 - min(max($0, -12), 12)) / 24 * 18 }
        let spline = NaturalSpline(xs: xs, ys: ys)
        return (0 ... 108).map { x in min(max(Int(spline.value(at: Double(x)).rounded()), 0), 18) }
    }
}

/// A natural cubic spline through points with increasing x.
struct NaturalSpline {
    private let xs: [Double], ys: [Double], m: [Double]

    init(xs: [Double], ys: [Double]) {
        self.xs = xs
        self.ys = ys
        let n = xs.count
        var m = Array(repeating: 0.0, count: n)
        guard n > 2 else { self.m = m; return }
        // Solve the tridiagonal system for the second derivatives, with zero at both ends.
        var c = Array(repeating: 0.0, count: n), d = Array(repeating: 0.0, count: n)
        for i in 1 ..< n - 1 {
            let h0 = xs[i] - xs[i - 1], h1 = xs[i + 1] - xs[i]
            let a = h0, b = 2 * (h0 + h1), cc = h1
            let r = 6 * ((ys[i + 1] - ys[i]) / h1 - (ys[i] - ys[i - 1]) / h0)
            let denominator = b - a * c[i - 1]
            c[i] = cc / denominator
            d[i] = (r - a * d[i - 1]) / denominator
        }
        for i in stride(from: n - 2, through: 1, by: -1) { m[i] = d[i] - c[i] * m[i + 1] }
        self.m = m
    }

    func value(at x: Double) -> Double {
        guard let last = xs.last, xs.count > 1 else { return ys.first ?? 0 }
        let i = min(max((xs.lastIndex { $0 <= x } ?? 0), 0), xs.count - 2)
        let h = xs[i + 1] - xs[i]
        let t = (min(max(x, xs[0]), last) - xs[i])
        let a = (xs[i + 1] - xs[i] - t) / h, b = t / h
        return a * ys[i] + b * ys[i + 1] + ((a * a * a - a) * m[i] + (b * b * b - b) * m[i + 1]) * h * h / 6
    }
}

extension SkinRenderer {
    public static func renderEqualizerWindow(_ state: EqualizerWindowState, skin: Skin) -> CGImage? {
        let size = state.isWindowshade ? EqualizerLayout.shadeSize : EqualizerLayout.size
        guard let image = render(EqualizerLayout.placements(for: state), skin: skin, size: size) else { return nil }
        guard !state.isWindowshade else { return image }
        return drawGraph(state.settings, skin: skin, over: image)
    }

    /// The preamp line and the curve, coloured row by row from the Skin's line colours.
    static func drawGraph(_ settings: EqualizerSettings, skin: Skin, over image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let h = CGFloat(image.height)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let graph = EqualizerLayout.graph
        if let line = skin.image(EqualizerSprites.preampLine) {
            let y = graph.minY + CGFloat(Int(((settings.preamp + 12) / 24 * 18).rounded()))
            context.draw(line, in: CGRect(x: graph.minX, y: h - y - 1, width: 113, height: 1))
        }
        guard let colours = skin.image(EqualizerSprites.graphLineColors) else { return context.makeImage() }
        let ys = EqualizerLayout.curve(settings.gains)
        var last = ys[0]
        for (x, y) in ys.enumerated() {
            let top = min(y, last), height = abs(last - y) + 1
            for row in top ..< top + height {
                // Each row of the curve takes its colour from the same row of the line colours.
                if let pixel = colours.cropping(to: CGRect(x: 0, y: row, width: 1, height: 1)) {
                    context.draw(pixel, in: CGRect(x: graph.minX + 2 + CGFloat(x), y: h - graph.minY - CGFloat(row) - 1,
                                                   width: 1, height: 1))
                }
            }
            last = y
        }
        return context.makeImage()
    }
}
