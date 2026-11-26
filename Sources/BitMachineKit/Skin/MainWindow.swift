import CoreGraphics
import Foundation

/// Everything the Main Window shows, as plain values.
public struct MainWindowState: Equatable, Sendable {
    public enum Playback: Sendable { case stopped, playing, paused }

    public var playback: Playback = .stopped
    /// Seconds into the Track.
    public var elapsed: TimeInterval = 0
    public var duration: TimeInterval = 0
    /// The time display counts down from the end of the Track instead of up.
    public var showsRemaining = false
    public var title = ""
    /// How far the title has scrolled, in pixels.
    public var titleScroll = 0
    public var kbps: Int?
    public var khz: Int?
    public var stereo = true
    /// 0...1
    public var volume: Double = 0.75
    /// -1 (left) ... 1 (right)
    public var balance: Double = 0
    public var shuffle = false
    public var repeats = false
    public var equalizerOpen = false
    public var playlistOpen = false
    public var isWindowshade = false
    public var isFocused = true
    /// The control the mouse is holding down, drawn pressed.
    public var pressed: MainWindowControl?
    /// While the position slider is dragged, where it is (0...1), overriding elapsed.
    public var seeking: Double?
    /// The analyzer, while there's something to show.
    public var visualizer: VisualizerBars?
    /// The title in the Skin's pixel font; when false, the window leaves it out for the app to draw in a real font.
    public var titleInPixelFont = true

    public init() {}

    public var progress: Double {
        if let seeking { return seeking }
        return duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
    }
}

/// The parts of the Main Window that respond to the mouse.
public enum MainWindowControl: Hashable, Sendable {
    case titleBar, options, minimize, shade, close
    case transport(TransportButton)
    case shuffle, repeats, equalizer, playlist
    case volume, balance, position
    case time
}

/// Where everything goes on the Main Window, in skin pixels from the top left.
public enum MainWindowLayout {
    public static let size = CGSize(width: 275, height: 116)
    public static let shadeSize = CGSize(width: 275, height: 14)

    public static let options = CGRect(x: 6, y: 3, width: 9, height: 9)
    public static let minimize = CGRect(x: 244, y: 3, width: 9, height: 9)
    public static let shade = CGRect(x: 254, y: 3, width: 9, height: 9)
    public static let close = CGRect(x: 264, y: 3, width: 9, height: 9)
    public static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    public static let clutterBar = CGPoint(x: 10, y: 22)
    public static let playIndicator = CGPoint(x: 26, y: 28)
    public static let workIndicator = CGPoint(x: 24, y: 28)
    public static let time = CGRect(x: 39, y: 26, width: 59, height: 13)
    public static let title = CGRect(x: 111, y: 24, width: 154, height: 6)
    public static let kbps = CGRect(x: 111, y: 43, width: 15, height: 6)
    public static let khz = CGRect(x: 156, y: 43, width: 10, height: 6)
    public static let mono = CGPoint(x: 212, y: 41)
    public static let stereo = CGPoint(x: 239, y: 41)
    public static let volume = CGRect(x: 107, y: 57, width: 68, height: 13)
    public static let balance = CGRect(x: 177, y: 57, width: 38, height: 13)
    public static let equalizerButton = CGRect(x: 219, y: 58, width: 23, height: 12)
    public static let playlistButton = CGRect(x: 242, y: 58, width: 23, height: 12)
    public static let position = CGRect(x: 16, y: 72, width: 248, height: 10)
    public static let shuffle = CGRect(x: 164, y: 89, width: 47, height: 15)
    /// 19 bars, 3 pixels wide with a pixel between, 16 high.
    public static let visualizer = CGRect(x: 24, y: 43, width: 76, height: 16)
    public static let repeats = CGRect(x: 210, y: 89, width: 28, height: 15)

    public static func transport(_ button: TransportButton) -> CGRect {
        switch button {
        case .previous: CGRect(x: 16, y: 88, width: 23, height: 18)
        case .play: CGRect(x: 39, y: 88, width: 23, height: 18)
        case .pause: CGRect(x: 62, y: 88, width: 23, height: 18)
        case .stop: CGRect(x: 85, y: 88, width: 23, height: 18)
        case .next: CGRect(x: 108, y: 88, width: 22, height: 18)
        case .eject: CGRect(x: 136, y: 89, width: 22, height: 16)
        }
    }

    /// The control under a point, front-most first.
    public static func control(at p: CGPoint, windowshade: Bool) -> MainWindowControl? {
        let common: [(CGRect, MainWindowControl)] = [
            (options, .options), (minimize, .minimize), (shade, .shade), (close, .close),
        ]
        if let hit = common.first(where: { $0.0.contains(p) }) { return hit.1 }
        if windowshade { return CGRect(origin: .zero, size: shadeSize).contains(p) ? .titleBar : nil }
        var controls: [(CGRect, MainWindowControl)] = TransportButton.allCases.map { (transport($0), .transport($0)) }
        controls += [
            (shuffle, .shuffle), (repeats, .repeats), (equalizerButton, .equalizer), (playlistButton, .playlist),
            (volume, .volume), (balance, .balance), (position, .position), (time, .time), (titleBar, .titleBar),
        ]
        return controls.first { $0.0.contains(p) }?.1
    }

    // MARK: Sliders

    /// The volume groove is 65 pixels wide (the last 3 of the 68-pixel bar are its end), less the 14-pixel thumb.
    public static let volumeTravel: CGFloat = 65 - 14
    public static let balanceTravel: CGFloat = 38 - 14
    public static let positionTravel: CGFloat = 248 - 29

    /// The volume a click or drag at `x` (in window pixels) sets, centring the thumb under the mouse.
    public static func volume(atX x: CGFloat) -> Double {
        Double(min(max((x - volume.minX - 7) / volumeTravel, 0), 1))
    }

    public static func balance(atX x: CGFloat) -> Double {
        Double(min(max((x - balance.minX - 7) / balanceTravel, 0), 1)) * 2 - 1
    }

    public static func position(atX x: CGFloat) -> Double {
        Double(min(max((x - position.minX - 14.5) / positionTravel, 0), 1))
    }

    // MARK: Drawing

    /// One sprite drawn at a point.
    public struct Placement: Equatable, Sendable {
        public let sprite: Sprite
        public let origin: CGPoint
    }

    /// The sprites that draw the Main Window in `state`, back to front.
    public static func placements(for state: MainWindowState) -> [Placement] {
        var out: [Placement] = []
        func put(_ sprite: Sprite, _ x: CGFloat, _ y: CGFloat) { out.append(Placement(sprite: sprite, origin: CGPoint(x: x, y: y))) }
        func put(_ sprite: Sprite, _ p: CGPoint) { put(sprite, p.x, p.y) }
        let held = state.pressed

        if state.isWindowshade {
            put(state.isFocused ? MainSprites.shadeBackgroundSelected : MainSprites.shadeBackground, 0, 0)
            titleButtons(&out, held: held, windowshade: true)
            return out
        }

        put(MainSprites.background, 0, 0)
        put(state.isFocused ? MainSprites.titleBarSelected : MainSprites.titleBar, 0, 0)
        titleButtons(&out, held: held, windowshade: false)
        put(MainSprites.clutterBar, clutterBar)

        switch state.playback {
        case .playing:
            put(MainSprites.playingIndicator, playIndicator)
            put(MainSprites.workingIndicator, workIndicator)
        case .paused: put(MainSprites.pausedIndicator, playIndicator)
        case .stopped: put(MainSprites.stoppedIndicator, playIndicator)
        }

        if state.playback != .stopped {
            let seconds = state.showsRemaining ? max(state.duration - state.elapsed, 0) : state.elapsed
            let total = min(Int(seconds), 99 * 60 + 59)
            let digits = [total / 600, total / 60 % 10, total % 60 / 10, total % 10]
            for (digit, x) in zip(digits, [9, 21, 39, 51] as [CGFloat]) {
                put(MainSprites.digit(digit), time.minX + x, time.minY)
            }
            if state.showsRemaining { put(MainSprites.minusSign, time.minX - 1, time.minY + 6) }
        }

        if state.titleInPixelFont {
            text(&out, scrolled(state.title, by: state.titleScroll, width: Int(title.width) / 5), at: title.origin)
        }
        if state.playback != .stopped {
            if let rate = state.kbps { text(&out, rightAligned(String(min(rate, 999)), 3), at: Self.kbps.origin) }
            if let rate = state.khz { text(&out, rightAligned(String(min(rate, 99)), 2), at: Self.khz.origin) }
        }
        let active = state.playback != .stopped
        put(active && !state.stereo ? MainSprites.monoSelected : MainSprites.mono, mono)
        put(active && state.stereo ? MainSprites.stereoSelected : MainSprites.stereo, stereo)

        put(MainSprites.volumeBackground(frame: Int((state.volume * 27).rounded())), volume.origin)
        put(held == .volume ? MainSprites.volumeThumbSelected : MainSprites.volumeThumb,
            volume.minX + (volumeTravel * state.volume).rounded(), volume.minY + 1)
        put(MainSprites.balanceBackground(frame: Int((abs(state.balance) * 27).rounded())), balance.origin)
        put(held == .balance ? MainSprites.balanceThumbSelected : MainSprites.balanceThumb,
            balance.minX + (balanceTravel * (state.balance + 1) / 2).rounded(), balance.minY + 1)

        put(MainSprites.equalizerButton(on: state.equalizerOpen, pressed: held == .equalizer), equalizerButton.origin)
        put(MainSprites.playlistButton(on: state.playlistOpen, pressed: held == .playlist), playlistButton.origin)

        put(MainSprites.positionBackground, position.origin)
        if state.playback != .stopped || state.seeking != nil {
            put(held == .position ? MainSprites.positionThumbSelected : MainSprites.positionThumb,
                position.minX + (positionTravel * state.progress).rounded(), position.minY)
        }

        for button in TransportButton.allCases {
            put(MainSprites.transport(button, pressed: held == .transport(button)), transport(button).origin)
        }
        put(MainSprites.shuffle(on: state.shuffle, pressed: held == .shuffle), shuffle.origin)
        put(MainSprites.repeatButton(on: state.repeats, pressed: held == .repeats), repeats.origin)
        return out
    }

    private static func titleButtons(_ out: inout [Placement], held: MainWindowControl?, windowshade: Bool) {
        func put(_ s: Sprite, _ r: CGRect) { out.append(Placement(sprite: s, origin: r.origin)) }
        put(held == .options ? MainSprites.optionsButtonDepressed : MainSprites.optionsButton, options)
        put(held == .minimize ? MainSprites.minimizeButtonDepressed : MainSprites.minimizeButton, minimize)
        if windowshade {
            put(held == .shade ? MainSprites.unshadeButtonDepressed : MainSprites.unshadeButton, shade)
        } else {
            put(held == .shade ? MainSprites.shadeButtonDepressed : MainSprites.shadeButton, shade)
        }
        put(held == .close ? MainSprites.closeButtonDepressed : MainSprites.closeButton, close)
    }

    private static func text(_ out: inout [Placement], _ string: String, at origin: CGPoint) {
        for (i, c) in string.enumerated() {
            out.append(Placement(sprite: MainSprites.character(c), origin: CGPoint(x: origin.x + CGFloat(i * 5), y: origin.y)))
        }
    }

    private static func rightAligned(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(width - s.count, 0)) + s
    }

    /// The `width` characters of the title showing after scrolling `pixels`, which wraps round with a gap, the way
    /// classic players scroll a long title. A title that fits doesn't scroll.
    static func scrolled(_ title: String, by pixels: Int, width: Int) -> String {
        let chars = Array(title)
        guard chars.count > width else { return title }
        let loop = chars + Array("  ***  ")
        let start = (pixels / 5) % loop.count
        return String((0 ..< width).map { loop[(start + $0) % loop.count] })
    }
}

/// Draws a Main Window into an image, one skin pixel to one image pixel.
public enum SkinRenderer {
    public static func render(_ placements: [MainWindowLayout.Placement], skin: Skin, size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        for placement in placements {
            guard let image = skin.image(placement.sprite) else { continue }
            // Core Graphics counts y from the bottom; the layout counts from the top.
            let rect = CGRect(x: placement.origin.x,
                              y: size.height - placement.origin.y - CGFloat(image.height),
                              width: CGFloat(image.width), height: CGFloat(image.height))
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }

    public static func renderMainWindow(_ state: MainWindowState, skin: Skin) -> CGImage? {
        let size = state.isWindowshade ? MainWindowLayout.shadeSize : MainWindowLayout.size
        guard let image = render(MainWindowLayout.placements(for: state), skin: skin, size: size) else { return nil }
        guard let visualizer = state.visualizer, !state.isWindowshade else { return image }
        return drawVisualizer(visualizer, colors: skin.visualizerColors, over: image)
    }

    /// The classic analyzer: colour 0 behind, colour 1 for the dot grid, colours 2 (top) to 17 (bottom) for the bars,
    /// colour 23 for the peaks.
    static func drawVisualizer(_ vis: VisualizerBars, colors: [RGB], over image: CGImage) -> CGImage? {
        guard colors.count >= 24, let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let h = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let area = MainWindowLayout.visualizer
        // A rect in layout coordinates (from the top) into Core Graphics' (from the bottom).
        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ hh: CGFloat, _ colour: RGB) {
            context.setFillColor(colour.cgColor)
            context.fill(CGRect(x: area.minX + x, y: h - (area.minY + y) - hh, width: w, height: hh))
        }
        fill(0, 0, area.width, area.height, colors[0])
        for y in stride(from: 1, to: 16, by: 2) {
            for x in stride(from: 1, to: 76, by: 2) { fill(CGFloat(x), CGFloat(y), 1, 1, colors[1]) }
        }
        for (i, level) in vis.bars.enumerated() {
            let x = CGFloat(i * 4)
            let height = Int((level * 16).rounded())
            for row in (16 - height) ..< 16 { fill(x, CGFloat(row), 3, 1, colors[2 + row]) }
            let peak = Int((vis.peaks[i] * 16).rounded())
            if peak > 0 { fill(x, CGFloat(16 - peak), 3, 1, colors[23]) }
        }
        return context.makeImage()
    }
}
