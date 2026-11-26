import CoreGraphics
import Foundation
import Testing
@testable import BitMachineKit

@Suite struct TunerTests {
    private let station = URL(string: "http://tuner.example/live")!

    @Test func liveTimeCountsUpEvenWhenAskedForRemaining() {
        var state = MainWindowState()
        state.playback = .playing
        state.elapsed = 75
        state.showsRemaining = true
        state.tuner = TunerReadout(frequency: Frequency(tenths: 943))
        let placements = MainWindowLayout.placements(for: state)
        #expect(!placements.contains { $0.sprite == MainSprites.minusSign })
        let digits = placements.filter { $0.sprite.sheet == .numbers }.map { Int($0.sprite.rect.minX) / 9 }
        #expect(digits == [0, 1, 1, 5])
    }

    @Test func thePositionBarIsTheTuningDial() {
        var state = MainWindowState()
        state.playback = .playing
        state.tuner = TunerReadout(frequency: Frequency(tenths: Frequency.highest))
        #expect(state.progress == 1)
        state.tuner = TunerReadout(frequency: Frequency(tenths: Frequency.lowest))
        #expect(state.progress == 0)
    }

    @Test func clickingTheVisualizerIsAControl() {
        #expect(MainWindowLayout.control(at: CGPoint(x: 50, y: 50), windowshade: false) == .visualizer)
    }

    @Test func signalBarsFollowTheBuffer() {
        #expect(TunerReadout(frequency: Frequency(tenths: 900), signal: 0).bars == 0)
        #expect(TunerReadout(frequency: Frequency(tenths: 900), signal: 0.1).bars == 1)
        #expect(TunerReadout(frequency: Frequency(tenths: 900), signal: 1).bars == 4)
        #expect(TunerReadout(frequency: Frequency(tenths: 900), signal: 3).bars == 4)
    }

    @Test func theFaceLightsTheFrequencysSegments() {
        let face = TunerFace.pixels(TunerReadout(frequency: Frequency(tenths: 943), signal: 1, preset: 2), stereo: true)
        // 9 (6 segments), 4 (4), 3 (5), the point, FM, ST, P2, four bars.
        let digitCells = face.lit.filter { $0.minY >= 1 && $0.minX >= 10 && $0.maxX <= 48 && $0.width + $0.height > 4 }
        #expect(digitCells.count == 15)
        #expect(face.lit.contains(CGRect(x: 37, y: 13, width: 2, height: 2)))
        // A blank hundreds digit stays dark, ghosts and all.
        #expect(!(face.lit + face.ghost).contains { $0.minX >= 10 && $0.maxX <= 17 })
        // Every pixel stays inside the 76×16 visualizer area.
        for r in face.lit + face.ghost {
            #expect(r.minX >= 0 && r.maxX <= 76 && r.minY >= 0 && r.maxY <= 16)
        }
    }

    @Test func theTunerDrawsInTheVisualizerColours() throws {
        var state = MainWindowState()
        state.playback = .playing
        state.tuner = TunerReadout(frequency: Frequency(tenths: 888), signal: 1)
        let skin = PlaceholderSkin.make()
        let image = try #require(SkinRenderer.renderMainWindow(state, skin: skin))
        let area = MainWindowLayout.visualizer
        // The top segment of the first 8, and a gap beside it.
        #expect(pixel(image, Int(area.minX) + 20, Int(area.minY) + 1) == skin.visualizerColors[2])
        #expect(pixel(image, Int(area.minX) + 9, Int(area.minY) + 4) == skin.visualizerColors[0])
        state.showsTuner = false
        let analyzer = try #require(SkinRenderer.renderMainWindow(state, skin: skin))
        #expect(pixel(analyzer, Int(area.minX) + 20, Int(area.minY) + 1) != skin.visualizerColors[2])
    }
}

@Suite struct RadioWindowTests {
    @Test func theDefaultSkinsTitleLettersAreMeasured() throws {
        let skin = PlaceholderSkin.make()
        let letters = skin.genLetters(selected: true)
        #expect(letters.count == 26)
        #expect(letters["A"] == Sprite(.gen, 1, 88, 4, 7))
        #expect(letters["Z"] == Sprite(.gen, 126, 88, 4, 7))
        #expect(skin.genLetters(selected: false)["R"]?.rect.minY == 96)
    }

    @Test func lettersOfDifferentWidthsAreFound() throws {
        // A row: background, a 2-wide letter, background, a 5-wide letter, background...
        let c = Canvas(width: 194, height: 109)
        c.fill(0, 0, 194, 109, RGB(255, 0, 255))
        var x = 1
        for (i, _) in GenSprites.letters.enumerated() {
            let w = i % 2 == 0 ? 2 : 5
            c.fill(x, 88, w, 7, RGB(10, 10, 10))
            x += w + 1
        }
        let letters = GenSprites.measureLetters(in: try #require(c.image()), selected: true)
        #expect(letters["A"]?.rect == CGRect(x: 1, y: 88, width: 2, height: 7))
        #expect(letters["B"]?.rect == CGRect(x: 4, y: 88, width: 5, height: 7))
        #expect(letters.count == 26)
    }

    @Test func hitTesting() {
        var state = RadioWindowState()
        state.stations = (0 ..< 30).map { Station(name: "S\($0)", url: URL(string: "http://s\($0).example/")!) }
        state.scroll = 5
        #expect(RadioWindowLayout.control(at: CGPoint(x: 268, y: 6), state: state) == .close)
        #expect(RadioWindowLayout.control(at: CGPoint(x: 100, y: 6), state: state) == .titleBar)
        #expect(RadioWindowLayout.control(at: CGPoint(x: 240, y: 28), state: state) == .top)
        #expect(RadioWindowLayout.control(at: CGPoint(x: 60, y: 28), state: state) == .search)
        #expect(RadioWindowLayout.control(at: CGPoint(x: 60, y: 39 + 12 * 2 + 3), state: state) == .row(7))
        #expect(RadioWindowLayout.control(at: CGPoint(x: 20, y: 205), state: state) == .preset(0))
        #expect(RadioWindowLayout.control(at: CGPoint(x: 250, y: 205), state: state) == .preset(5))
        state.stations = Array(state.stations.prefix(6))
        #expect(RadioWindowLayout.control(at: CGPoint(x: 60, y: 39 + 12 * 3 + 3), state: state) == nil)
        #expect(state.maxScroll == 0)
    }

    @Test func theFrameCoversTheWindowAndCentresTheTitle() throws {
        let placements = RadioWindowLayout.placements(focused: true, closePressed: false) { _ in 4 }
        #expect(placements.contains { $0.sprite == GenSprites.topLeft(true) && $0.origin == .zero })
        #expect(placements.contains { $0.sprite == GenSprites.topRight(true) && $0.origin.x == 250 })
        #expect(placements.contains { $0.sprite == GenSprites.bottomRight && $0.origin == CGPoint(x: 150, y: 218) })
        let letters = RadioWindowLayout.titleLetters { _ in 4 }
        #expect(letters.map(\.0) == Array("RADIO"))
        let first = try #require(letters.first?.1)
        let last = try #require(letters.last?.1)
        // Centred to within a pixel.
        #expect(abs((first + last + 4) / 2 - 137.5) <= 1)
    }

    @Test func rendersAtTheAskedScale() throws {
        var state = RadioWindowState()
        state.stations = [Station(name: "Groove", url: URL(string: "http://g.example/")!, codec: "MP3", bitrate: 128)]
        state.status = "1 station"
        let skin = PlaceholderSkin.make()
        let image = try #require(SkinRenderer.renderRadioWindow(state, skin: skin, scale: 2))
        #expect(image.width == 550 && image.height == 464)
        // The list's background is the Skin's Playlist background.
        let plain = try #require(SkinRenderer.renderRadioWindow(state, skin: skin))
        #expect(pixel(plain, 200, 150) == skin.playlistColors.normalBackground)
    }
}
