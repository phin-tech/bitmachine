import CoreGraphics
import Foundation
import ImageIO

/// A classic `.wsz` Skin: its bitmaps, visualizer colours, Playlist colours and window shapes. A Skin that leaves
/// something out falls back to the Default Skin for it, sprite by sprite, the way classic players did.
public final class Skin: @unchecked Sendable {
    public let name: String
    private let sheets: [SpriteSheet: CGImage]
    /// The 24 visualizer colours (`viscolor.txt`).
    public let visualizerColors: [RGB]
    public let playlistColors: PlaylistColors
    /// Window shapes from `region.txt`, by section (`Normal`, `WindowShade`, `Equalizer`, `EqualizerWS`).
    public let regions: [String: [[CGPoint]]]
    private let fallback: Skin?
    private var cache: [Sprite: CGImage] = [:]
    private let lock = NSLock()

    init(name: String, sheets: [SpriteSheet: CGImage], visualizerColors: [RGB], playlistColors: PlaylistColors,
         regions: [String: [[CGPoint]]], fallback: Skin?) {
        self.name = name
        self.sheets = sheets
        self.visualizerColors = visualizerColors
        self.playlistColors = playlistColors
        self.regions = regions
        self.fallback = fallback
    }

    /// The sheets this Skin has itself, without its fallback.
    public var ownSheets: Set<SpriteSheet> { Set(sheets.keys) }

    /// The sprite's image: from this Skin's sheet if the sheet has it, else from the fallback.
    public func image(_ sprite: Sprite) -> CGImage? {
        // Within a Skin first: `nums_ex.bmp` replaces `numbers.bmp`'s digits when the Skin has it, and a Skin
        // without `balance.bmp` draws its balance bar from `volume.bmp`, as classic players did.
        if sprite.sheet == .numbers, sprite != MainSprites.minusSign, sheets[.numsEx] != nil,
           let image = ownImage(Sprite(.numsEx, sprite.rect)) {
            return image
        }
        if sprite.sheet == .balance, sheets[.balance] == nil, sheets[.volume] != nil,
           let image = ownImage(Sprite(.volume, sprite.rect)) {
            return image
        }
        if let image = ownImage(sprite) { return image }
        return fallback?.image(sprite)
    }

    /// The sprite from this Skin's own sheet, if the sheet is there and big enough.
    private func ownImage(_ sprite: Sprite) -> CGImage? {
        lock.lock()
        if let cached = cache[sprite] { lock.unlock(); return cached }
        lock.unlock()
        var image: CGImage?
        if let sheet = sheets[sprite.sheet], sprite.rect.maxX <= CGFloat(sheet.width),
           sprite.rect.maxY <= CGFloat(sheet.height) {
            image = sheet.cropping(to: sprite.rect)
        }
        if let image {
            lock.lock(); cache[sprite] = image; lock.unlock()
        }
        return image
    }

    /// The Main Window's text colours, read from the text font (`text.bmp`): its background, and the colour most of
    /// its letters are drawn in. For drawing the title in a real font that matches the Skin.
    public var textColors: (text: RGB, background: RGB) {
        lock.lock()
        if let cached = cachedTextColors { lock.unlock(); return cached }
        lock.unlock()
        let colors = Self.sampleTextColors(image(Sprite(.text, 0, 0, 135, 6)))
        lock.lock(); cachedTextColors = colors; lock.unlock()
        return colors
    }

    private var cachedTextColors: (text: RGB, background: RGB)?

    static func sampleTextColors(_ letters: CGImage?) -> (text: RGB, background: RGB) {
        let fallback = (text: RGB(0, 255, 0), background: RGB(0, 0, 0))
        guard let letters, let context = CGContext(
            data: nil, width: letters.width, height: letters.height, bitsPerComponent: 8,
            bytesPerRow: letters.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return fallback }
        context.draw(letters, in: CGRect(x: 0, y: 0, width: letters.width, height: letters.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }
        var counts: [RGB: Int] = [:]
        for i in 0 ..< letters.width * letters.height {
            counts[RGB(data[i * 4], data[i * 4 + 1], data[i * 4 + 2]), default: 0] += 1
        }
        // The background is the commonest colour; the text, the commonest of the rest.
        let ranked = counts.sorted { $0.value > $1.value }.map(\.key)
        guard let background = ranked.first else { return fallback }
        return (ranked.dropFirst().first ?? fallback.text, background)
    }

    // MARK: Loading

    public enum LoadError: Error, Equatable {
        case empty
    }

    /// Loads a `.wsz` (or `.zip`) archive, or a folder of an unpacked Skin.
    public static func load(contentsOf url: URL, fallback: Skin?) throws -> Skin {
        let name = url.deletingPathExtension().lastPathComponent
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            var files: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                    files[file.path.replacingOccurrences(of: url.path + "/", with: "")] = data
                }
            }
            return try load(files: files, name: name, fallback: fallback)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try load(files: ZipReader.entries(of: data), name: name, fallback: fallback)
    }

    /// Makes a Skin from a `.wsz`'s files, keyed by their path in it. Names are matched without case, and a file in a
    /// folder counts (many skins were zipped with their folder); the shallowest match wins.
    public static func load(files: [String: Data], name: String, fallback: Skin?) throws -> Skin {
        var byName: [String: (depth: Int, data: Data)] = [:]
        for (path, data) in files {
            let components = path.split(separator: "/")
            guard let last = components.last, !path.contains("__MACOSX") else { continue }
            let key = last.lowercased()
            if let existing = byName[key], existing.depth <= components.count { continue }
            byName[key] = (components.count, data)
        }
        var sheets: [SpriteSheet: CGImage] = [:]
        for sheet in SpriteSheet.allCases {
            guard let data = byName[sheet.fileName]?.data, let image = decodeImage(data) else { continue }
            sheets[sheet] = image
        }
        let text = { (file: String) in byName[file].map { decodeText($0.data) } }
        if sheets.isEmpty, text("viscolor.txt") == nil { throw LoadError.empty }

        return Skin(name: name, sheets: sheets,
                    visualizerColors: text("viscolor.txt").map { parseVisualizerColors($0, fallback: fallback) }
                        ?? fallback?.visualizerColors ?? Array(repeating: RGB(0, 0, 0), count: 24),
                    playlistColors: text("pledit.txt").map { PlaylistColors.parse($0, fallback: fallback?.playlistColors) }
                        ?? fallback?.playlistColors ?? .standard,
                    regions: text("region.txt").map(parseRegions) ?? [:],
                    fallback: fallback)
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Text files

    /// `viscolor.txt`: one `r,g,b` per line (commas optional), anything after is a comment. Missing lines keep the
    /// fallback's colours.
    static func parseVisualizerColors(_ text: String, fallback: Skin?) -> [RGB] {
        var colors = fallback?.visualizerColors ?? Array(repeating: RGB(0, 0, 0), count: 24)
        let regex = /^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)/
        var i = 0
        for line in text.split(whereSeparator: \.isNewline) where i < 24 {
            guard let m = try? regex.firstMatch(in: String(line)) else { continue }
            colors[i] = RGB(UInt8(clamping: Int(m.1) ?? 0), UInt8(clamping: Int(m.2) ?? 0), UInt8(clamping: Int(m.3) ?? 0))
            i += 1
        }
        return colors
    }

    /// `region.txt`: per section, `NumPoints` lists each polygon's point count and `PointList` all their points.
    static func parseRegions(_ text: String) -> [String: [[CGPoint]]] {
        var result: [String: [[CGPoint]]] = [:]
        for (section, values) in parseINI(text) {
            guard let counts = values["numpoints"], let list = values["pointlist"] else { continue }
            let numbers = list.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            var points: [CGPoint] = []
            var i = 0
            while i + 1 < numbers.count { points.append(CGPoint(x: numbers[i], y: numbers[i + 1])); i += 2 }
            var polygons: [[CGPoint]] = []
            var index = 0
            for count in counts.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                defer { index += max(count, 0) }
                guard count >= 3, index + count <= points.count else { continue }
                polygons.append(Array(points[index ..< index + count]))
            }
            if !polygons.isEmpty { result[section] = polygons }
        }
        return result
    }

    /// A forgiving INI reader: sections and keys are matched without case (keys come back lowercased, sections as
    /// written), `;` starts a comment line, and anything after a second `=` is ignored.
    static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let section, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            result[section, default: [:]][key] = value
        }
        return result
    }
}

public struct RGB: Hashable, Sendable {
    public var r, g, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// `#RRGGBB` (the `#` optional), as `pledit.txt` writes colours.
    public init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else { return nil }
        self.init(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// The Playlist Window's colours and font, from `pledit.txt`'s `[Text]` section.
public struct PlaylistColors: Hashable, Sendable {
    public var normal: RGB
    public var current: RGB
    public var normalBackground: RGB
    public var selectedBackground: RGB
    public var font: String

    public static let standard = PlaylistColors(normal: RGB(0, 255, 0), current: RGB(255, 255, 255),
                                                normalBackground: RGB(0, 0, 0), selectedBackground: RGB(0, 0, 198),
                                                font: "Arial")

    static func parse(_ text: String, fallback: PlaylistColors?) -> PlaylistColors {
        var colors = fallback ?? .standard
        let section = Skin.parseINI(text).first { $0.key.lowercased() == "text" }?.value ?? [:]
        if let c = section["normal"].flatMap(RGB.init(hex:)) { colors.normal = c }
        if let c = section["current"].flatMap(RGB.init(hex:)) { colors.current = c }
        if let c = section["normalbg"].flatMap(RGB.init(hex:)) { colors.normalBackground = c }
        if let c = section["selectedbg"].flatMap(RGB.init(hex:)) { colors.selectedBackground = c }
        if let f = section["font"], !f.isEmpty { colors.font = f }
        return colors
    }
}
