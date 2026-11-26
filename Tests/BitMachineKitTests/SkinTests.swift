import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BitMachineKit

// MARK: Helpers

/// A BMP of one colour.
func solidBMP(_ width: Int, _ height: Int, _ colour: RGB) -> Data {
    let c = Canvas(width: width, height: height)
    c.fill(0, 0, width, height, colour)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.bmp.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.image()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Zips files with the system `zip`, the way skins were made, and returns the archive.
func zipArchive(_ files: [String: Data], compress: Bool = true) throws -> Data {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (path, data) in files {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = folder
    zip.arguments = ["-q", "-r", compress ? "-9" : "-0", "out.zip"] + files.keys.sorted()
    try zip.run()
    zip.waitUntilExit()
    return try Data(contentsOf: folder.appendingPathComponent("out.zip"))
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGB {
    let c = Canvas(width: image.width, height: image.height)
    c.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = c.context.data!.assumingMemoryBound(to: UInt8.self)
    let offset = y * c.context.bytesPerRow + x * 4
    return RGB(data[offset], data[offset + 1], data[offset + 2])
}

// MARK: Zip

@Suite struct ZipReaderTests {
    @Test func readsStoredAndDeflatedEntries() throws {
        let files = ["main.bmp": Data(repeating: 7, count: 5000), "Folder/viscolor.txt": Data("1,2,3".utf8)]
        for compress in [true, false] {
            let entries = try ZipReader.entries(of: zipArchive(files, compress: compress))
            #expect(entries["main.bmp"] == files["main.bmp"])
            #expect(entries["Folder/viscolor.txt"] == files["Folder/viscolor.txt"])
            #expect(entries["Folder/"] == nil)
        }
    }

    @Test func rejectsWhatIsNotAZip() {
        #expect(throws: ZipReader.Failure.notAZip) { try ZipReader.entries(of: Data("hello".utf8)) }
    }

    @Test func capsEntrySize() throws {
        let archive = try zipArchive(["big.bmp": Data(repeating: 0, count: 100_000)])
        #expect(throws: ZipReader.Failure.tooLarge) {
            try ZipReader.entries(of: archive, limits: .init(maxEntrySize: 50_000))
        }
    }
}

// MARK: Skin

@Suite struct SkinTests {
    let placeholder = PlaceholderSkin.make()

    @Test func placeholderHasEverySheet() {
        #expect(placeholder.ownSheets == Set(SpriteSheet.allCases))
        #expect(placeholder.visualizerColors.count == 24)
    }

    @Test func matchesNamesWithoutCaseAndInFolders() throws {
        let archive = try zipArchive([
            "MySkin/MAIN.BMP": solidBMP(275, 116, RGB(255, 0, 0)),
            "MySkin/CButtons.bmp": solidBMP(136, 36, RGB(0, 255, 0)),
        ])
        let skin = try Skin.load(files: ZipReader.entries(of: archive), name: "MySkin", fallback: placeholder)
        #expect(skin.ownSheets == [.main, .cbuttons])
        #expect(pixel(skin.image(MainSprites.background)!, 10, 10) == RGB(255, 0, 0))
    }

    @Test func shallowestFileWins() throws {
        let skin = try Skin.load(files: [
            "a/b/main.bmp": solidBMP(275, 116, RGB(0, 0, 255)),
            "main.bmp": solidBMP(275, 116, RGB(255, 0, 0)),
        ], name: "x", fallback: nil)
        #expect(pixel(skin.image(MainSprites.background)!, 0, 0) == RGB(255, 0, 0))
    }

    @Test func missingSheetsFallBackToTheDefaultSkin() throws {
        let skin = try Skin.load(files: ["main.bmp": solidBMP(275, 116, RGB(255, 0, 0))], name: "x",
                                 fallback: placeholder)
        let play = MainSprites.transport(.play, pressed: false)
        #expect(skin.image(play) != nil)
        #expect(pixel(skin.image(play)!, 0, 0) == pixel(placeholder.image(play)!, 0, 0))
    }

    @Test func sheetTooSmallForASpriteFallsBack() throws {
        // Some skins ship a short volume.bmp without the thumbs at the bottom.
        let skin = try Skin.load(files: ["volume.bmp": solidBMP(68, 420, RGB(255, 0, 0))], name: "x",
                                 fallback: placeholder)
        #expect(pixel(skin.image(MainSprites.volumeBackground(frame: 0))!, 0, 0) == RGB(255, 0, 0))
        #expect(pixel(skin.image(MainSprites.volumeThumb)!, 5, 5) == pixel(placeholder.image(MainSprites.volumeThumb)!, 5, 5))
    }

    @Test func extendedDigitsReplaceNumbersWithinASkin() throws {
        let skin = try Skin.load(files: ["numbers.bmp": solidBMP(99, 13, RGB(255, 0, 0)),
                                         "nums_ex.bmp": solidBMP(108, 13, RGB(0, 0, 255))], name: "x", fallback: placeholder)
        #expect(pixel(skin.image(MainSprites.digit(3))!, 4, 4) == RGB(0, 0, 255))
        #expect(pixel(skin.image(MainSprites.minusSign)!, 0, 0) == RGB(255, 0, 0))
    }

    @Test func balanceFallsBackToTheSkinsOwnVolume() throws {
        let skin = try Skin.load(files: ["volume.bmp": solidBMP(68, 433, RGB(0, 255, 0))], name: "x", fallback: placeholder)
        #expect(pixel(skin.image(MainSprites.balanceBackground(frame: 3))!, 2, 2) == RGB(0, 255, 0))
        #expect(pixel(skin.image(MainSprites.balanceThumb)!, 2, 2) == RGB(0, 255, 0))
    }

    @Test func textColoursComeFromTheTextFont() {
        let colors = placeholder.textColors
        #expect(colors.background == PlaceholderSkin.Palette.display)
        #expect(colors.text == PlaceholderSkin.Palette.amber)
    }

    @Test func aRealFontTitleLeavesThePixelTitleOut() {
        var state = MainWindowState()
        state.title = "abc"
        #expect(MainWindowLayout.placements(for: state).contains { $0.sprite.sheet == .text })
        state.titleInPixelFont = false
        #expect(!MainWindowLayout.placements(for: state).contains { $0.sprite.sheet == .text })
    }

    @Test func anEmptyArchiveIsNotASkin() {
        #expect(throws: Skin.LoadError.empty) { try Skin.load(files: ["readme.txt": Data()], name: "x", fallback: nil) }
    }

    @Test func parsesVisualizerColours() {
        let colours = Skin.parseVisualizerColors("0,0,0 // background\n24, 33, 41\n 255 255 255 ; peak\n", fallback: placeholder)
        #expect(colours[0] == RGB(0, 0, 0))
        #expect(colours[1] == RGB(24, 33, 41))
        #expect(colours[2] == RGB(255, 255, 255))
        #expect(colours[3] == placeholder.visualizerColors[3])
    }

    @Test func parsesPlaylistColours() {
        let colours = PlaylistColors.parse("[Text]\nNormal=#00FF00\ncurrent = #FFFFFF\nNormalBG=#000000\nSelectedBG=#0000C6\nFont=Arial\n",
                                           fallback: nil)
        #expect(colours.normal == RGB(0, 255, 0))
        #expect(colours.current == RGB(255, 255, 255))
        #expect(colours.selectedBackground == RGB(0, 0, 198))
        #expect(colours.font == "Arial")
    }

    @Test func parsesRegions() {
        let regions = Skin.parseRegions("""
        [Normal]
        NumPoints=4, 2, 3
        PointList=0,0, 275,0, 275,116, 0,116,  1,1, 2,2,  10 10 20 10 15 20
        [WindowShade]
        NumPoints=4
        """)
        #expect(regions["Normal"]?.count == 2)
        #expect(regions["Normal"]?[0][2] == CGPoint(x: 275, y: 116))
        #expect(regions["Normal"]?[1] == [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 15, y: 20)])
        #expect(regions["WindowShade"] == nil)
    }
}

// MARK: Main Window

@Suite struct MainWindowTests {
    @Test func timeShowsMinutesAndSeconds() {
        var state = MainWindowState()
        state.playback = .playing
        state.elapsed = 83
        let digits = MainWindowLayout.placements(for: state).filter { $0.sprite.sheet == .numbers }
        #expect(digits.map(\.sprite) == [0, 1, 2, 3].map(MainSprites.digit))
        #expect(digits.map(\.origin.x) == [48, 60, 78, 90])
    }

    @Test func remainingTimeHasAMinusSign() {
        var state = MainWindowState()
        state.playback = .paused
        state.elapsed = 10
        state.duration = 70
        state.showsRemaining = true
        let numbers = MainWindowLayout.placements(for: state).filter { $0.sprite.sheet == .numbers }
        #expect(numbers.contains { $0.sprite == MainSprites.minusSign })
        #expect(numbers.filter { $0.sprite != MainSprites.minusSign }.map(\.sprite) == [0, 1, 0, 0].map(MainSprites.digit))
    }

    @Test func stoppedHidesTheTimeAndPositionThumb() {
        let placements = MainWindowLayout.placements(for: MainWindowState())
        #expect(!placements.contains { $0.sprite.sheet == .numbers })
        #expect(!placements.contains { $0.sprite == MainSprites.positionThumb })
        #expect(placements.contains { $0.sprite == MainSprites.stoppedIndicator })
    }

    @Test func longTitlesScrollAndWrap() {
        #expect(MainWindowLayout.scrolled("short", by: 50, width: 31) == "short")
        let title = String(repeating: "a", count: 30) + "bcdef"
        #expect(MainWindowLayout.scrolled(title, by: 0, width: 31).count == 31)
        #expect(MainWindowLayout.scrolled(title, by: 150, width: 31).hasPrefix("bcdef  ***"))
    }

    @Test func hitTesting() {
        #expect(MainWindowLayout.control(at: CGPoint(x: 268, y: 7), windowshade: false) == .close)
        #expect(MainWindowLayout.control(at: CGPoint(x: 50, y: 95), windowshade: false) == .transport(.play))
        #expect(MainWindowLayout.control(at: CGPoint(x: 100, y: 5), windowshade: false) == .titleBar)
        #expect(MainWindowLayout.control(at: CGPoint(x: 120, y: 60), windowshade: false) == .volume)
        #expect(MainWindowLayout.control(at: CGPoint(x: 5, y: 60), windowshade: false) == nil)
        #expect(MainWindowLayout.control(at: CGPoint(x: 100, y: 10), windowshade: true) == .titleBar)
        #expect(MainWindowLayout.control(at: CGPoint(x: 50, y: 95), windowshade: true) == nil)
    }

    @Test func slidersMapTheMouseToValues() {
        #expect(MainWindowLayout.volume(atX: 0) == 0)
        #expect(MainWindowLayout.volume(atX: 500) == 1)
        #expect(abs(MainWindowLayout.balance(atX: MainWindowLayout.balance.midX)) < 0.01)
        #expect(MainWindowLayout.position(atX: MainWindowLayout.position.maxX) == 1)
    }

    @Test func volumeThumbStaysInItsGroove() {
        var state = MainWindowState()
        state.volume = 1
        let thumb = MainWindowLayout.placements(for: state).first { $0.sprite == MainSprites.volumeThumb }!
        // The groove ends 3 pixels short of the 68-pixel bar.
        #expect(thumb.origin.x + 14 == MainWindowLayout.volume.minX + 65)
    }

    /// Renders a skin whose every sheet is one colour, and checks pixels land where the layout says, the right way up.
    @Test func rendersSpritesInPlace() throws {
        let colours: [SpriteSheet: RGB] = [.main: RGB(200, 0, 0), .titlebar: RGB(0, 200, 0), .cbuttons: RGB(0, 0, 200),
                                           .posbar: RGB(200, 200, 0)]
        var files: [String: Data] = [:]
        for (sheet, colour) in colours {
            let (w, h) = PlaceholderSkin.sizes[sheet]!
            files[sheet.fileName] = solidBMP(w, h, colour)
        }
        let skin = try Skin.load(files: files, name: "solid", fallback: PlaceholderSkin.make())
        let image = try #require(SkinRenderer.renderMainWindow(MainWindowState(), skin: skin))
        #expect(image.width == 275 && image.height == 116)
        #expect(pixel(image, 2, 60) == RGB(200, 0, 0))     // background
        #expect(pixel(image, 100, 5) == RGB(0, 200, 0))    // title bar, at the top
        #expect(pixel(image, 50, 95) == RGB(0, 0, 200))    // play button, near the bottom
        #expect(pixel(image, 100, 76) == RGB(200, 200, 0)) // position bar

        var shade = MainWindowState()
        shade.isWindowshade = true
        let shaded = try #require(SkinRenderer.renderMainWindow(shade, skin: skin))
        #expect(shaded.height == 14)
        #expect(pixel(shaded, 100, 5) == RGB(0, 200, 0))
    }
}
