import CoreGraphics

// Sprite coordinates and Main Window positions follow the classic skin format as documented by Webamp
// (https://github.com/captbaritone/webamp, packages/webamp/js/skinSprites.ts and css/main-window.css at 99a31e2),
// MIT License, Copyright (c) 2015 Jordan Eldredge. See THIRD_PARTY_NOTICES.md.

/// One bitmap file of a Skin.
public enum SpriteSheet: String, CaseIterable, Sendable {
    case main, cbuttons, titlebar, numbers, numsEx = "nums_ex", playpaus, monoster, posbar, shufrep, volume,
         balance, text, eqmain, eqEx = "eq_ex", pledit, gen

    /// The file's name in a `.wsz`, lowercased.
    public var fileName: String { rawValue + ".bmp" }
}

/// A rectangle of a sheet, in the sheet's pixels with the origin at the top left.
public struct Sprite: Hashable, Sendable {
    public let sheet: SpriteSheet
    public let rect: CGRect

    public init(_ sheet: SpriteSheet, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.sheet = sheet
        rect = CGRect(x: x, y: y, width: width, height: height)
    }

    public init(_ sheet: SpriteSheet, _ rect: CGRect) {
        self.sheet = sheet
        self.rect = rect
    }
}

/// The sprites the Main Window draws.
public enum MainSprites {
    public static let background = Sprite(.main, 0, 0, 275, 116)

    public static let titleBar = Sprite(.titlebar, 27, 15, 275, 14)
    public static let titleBarSelected = Sprite(.titlebar, 27, 0, 275, 14)
    public static let shadeBackground = Sprite(.titlebar, 27, 42, 275, 14)
    public static let shadeBackgroundSelected = Sprite(.titlebar, 27, 29, 275, 14)
    public static let optionsButton = Sprite(.titlebar, 0, 0, 9, 9)
    public static let optionsButtonDepressed = Sprite(.titlebar, 0, 9, 9, 9)
    public static let minimizeButton = Sprite(.titlebar, 9, 0, 9, 9)
    public static let minimizeButtonDepressed = Sprite(.titlebar, 9, 9, 9, 9)
    public static let shadeButton = Sprite(.titlebar, 0, 18, 9, 9)
    public static let shadeButtonDepressed = Sprite(.titlebar, 9, 18, 9, 9)
    public static let unshadeButton = Sprite(.titlebar, 0, 27, 9, 9)
    public static let unshadeButtonDepressed = Sprite(.titlebar, 9, 27, 9, 9)
    public static let closeButton = Sprite(.titlebar, 18, 0, 9, 9)
    public static let closeButtonDepressed = Sprite(.titlebar, 18, 9, 9, 9)
    public static let clutterBar = Sprite(.titlebar, 304, 0, 8, 43)

    public static func transport(_ button: TransportButton, pressed: Bool) -> Sprite {
        let y = pressed ? (button == .eject ? 16 : 18) : 0
        switch button {
        case .previous: return Sprite(.cbuttons, 0, y, 23, 18)
        case .play: return Sprite(.cbuttons, 23, y, 23, 18)
        case .pause: return Sprite(.cbuttons, 46, y, 23, 18)
        case .stop: return Sprite(.cbuttons, 69, y, 23, 18)
        case .next: return Sprite(.cbuttons, 92, y, 22, 18)
        case .eject: return Sprite(.cbuttons, 114, y, 22, 16)
        }
    }

    public static let playingIndicator = Sprite(.playpaus, 0, 0, 9, 9)
    public static let pausedIndicator = Sprite(.playpaus, 9, 0, 9, 9)
    public static let stoppedIndicator = Sprite(.playpaus, 18, 0, 9, 9)
    public static let workingIndicator = Sprite(.playpaus, 39, 0, 3, 9)

    public static func digit(_ n: Int) -> Sprite { Sprite(.numbers, 9 * n, 0, 9, 13) }
    public static let minusSign = Sprite(.numbers, 20, 6, 5, 1)

    public static let stereo = Sprite(.monoster, 0, 12, 29, 12)
    public static let stereoSelected = Sprite(.monoster, 0, 0, 29, 12)
    public static let mono = Sprite(.monoster, 29, 12, 27, 12)
    public static let monoSelected = Sprite(.monoster, 29, 0, 27, 12)

    public static let positionBackground = Sprite(.posbar, 0, 0, 248, 10)
    public static let positionThumb = Sprite(.posbar, 248, 0, 29, 10)
    public static let positionThumbSelected = Sprite(.posbar, 278, 0, 29, 10)

    /// The volume bar has 28 frames, 15 pixels apart, from silent to full.
    public static func volumeBackground(frame: Int) -> Sprite { Sprite(.volume, 0, 15 * frame, 68, 13) }
    public static let volumeThumb = Sprite(.volume, 15, 422, 14, 11)
    public static let volumeThumbSelected = Sprite(.volume, 0, 422, 14, 11)

    /// The balance bar has 28 frames, 15 pixels apart, from centred to fully to one side.
    public static func balanceBackground(frame: Int) -> Sprite { Sprite(.balance, 9, 15 * frame, 38, 13) }
    public static let balanceThumb = Sprite(.balance, 15, 422, 14, 11)
    public static let balanceThumbSelected = Sprite(.balance, 0, 422, 14, 11)

    public static func shuffle(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.shufrep, 28, (on ? 30 : 0) + (pressed ? 15 : 0), 47, 15)
    }

    public static func repeatButton(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.shufrep, 0, (on ? 30 : 0) + (pressed ? 15 : 0), 28, 15)
    }

    public static func equalizerButton(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.shufrep, pressed ? 46 : 0, on ? 73 : 61, 23, 12)
    }

    public static func playlistButton(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.shufrep, pressed ? 69 : 23, on ? 73 : 61, 23, 12)
    }

    /// One 5×6 character of the text font, or a space for a character the font doesn't have.
    public static func character(_ c: Character) -> Sprite {
        let (row, column) = textFont[Character(c.lowercased())] ?? (0, 30)
        return Sprite(.text, column * 5, row * 6, 5, 6)
    }

    static let textFont: [Character: (Int, Int)] = {
        var table: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz\"@".enumerated() { table[c] = (0, i) }
        table[" "] = (0, 30)
        for (i, c) in "0123456789….:()-'!_+\\/[]^&%,=$#".enumerated() { table[c] = (1, i) }
        for (i, c) in "åöä?*".enumerated() { table[c] = (2, i) }
        table["<"] = (1, 22); table[">"] = (1, 23); table["{"] = (1, 22); table["}"] = (1, 23)
        return table
    }()
}

public enum TransportButton: String, CaseIterable, Codable, Sendable {
    case previous, play, pause, stop, next, eject
}
