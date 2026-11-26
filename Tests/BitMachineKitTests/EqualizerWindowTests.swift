import CoreGraphics
import Foundation
import Testing
@testable import BitMachineKit

@Suite struct EqualizerWindowTests {
    @Test func slidersMapTheMouseToGains() {
        #expect(EqualizerLayout.gain(atY: 0) == 12)
        #expect(EqualizerLayout.gain(atY: 500) == -12)
        #expect(EqualizerLayout.gain(atY: EqualizerLayout.preamp.minY + 5.5 + 25.5) == 0)
        #expect(EqualizerLayout.gain(atY: EqualizerLayout.preamp.minY + 5.5 + 26.5) == 0)  // snaps near the middle
    }

    @Test func aGainPicksItsFrameAndThumb() {
        var state = EqualizerWindowState()
        state.settings.gains[0] = 12
        state.settings.gains[9] = -12
        let placements = EqualizerLayout.placements(for: state)
        let backgrounds = placements.filter { $0.sprite.rect.height == 63 }
        #expect(backgrounds.count == 11)
        #expect(backgrounds[1].sprite == EqualizerSprites.sliderBackground(frame: 27))
        #expect(backgrounds[10].sprite == EqualizerSprites.sliderBackground(frame: 0))
        #expect(backgrounds[0].sprite == EqualizerSprites.sliderBackground(frame: 14))  // preamp at 0 dB
        // Frame 14 is the first of the second row.
        #expect(EqualizerSprites.sliderBackground(frame: 14).rect.origin == CGPoint(x: 13, y: 229))
        let thumbs = placements.filter { $0.sprite == EqualizerSprites.thumb }
        #expect(thumbs[1].origin.y == 39)       // +12: top
        #expect(thumbs.count == 11)
        #expect(thumbs.last.map { Int($0.origin.y) } == 90) // -12: bottom (39 + 51)
    }

    @Test func hitTesting() {
        #expect(EqualizerLayout.control(at: CGPoint(x: 80, y: 60), windowshade: false) == .band(0))
        #expect(EqualizerLayout.control(at: CGPoint(x: 245, y: 60), windowshade: false) == .band(9))
        #expect(EqualizerLayout.control(at: CGPoint(x: 25, y: 60), windowshade: false) == .preamp)
        #expect(EqualizerLayout.control(at: CGPoint(x: 20, y: 22), windowshade: false) == .on)
        #expect(EqualizerLayout.control(at: CGPoint(x: 268, y: 7), windowshade: false) == .close)
        #expect(EqualizerLayout.control(at: CGPoint(x: 100, y: 5), windowshade: false) == .titleBar)
        #expect(EqualizerLayout.control(at: CGPoint(x: 80, y: 60), windowshade: true) == nil)
    }

    @Test func theCurvePassesThroughTheBands() {
        let flat = EqualizerLayout.curve(Array(repeating: 0, count: 10))
        #expect(flat.count == 109)
        #expect(Set(flat) == [9])
        var gains = Array(repeating: 0.0, count: 10)
        gains[0] = 12
        gains[9] = -12
        let curve = EqualizerLayout.curve(gains)
        #expect(curve.first == 0)
        #expect(curve.last == 18)
    }

    @Test func rendersWithThePlaceholderSkin() throws {
        let skin = PlaceholderSkin.make()
        var state = EqualizerWindowState()
        state.settings.on = true
        let image = try #require(SkinRenderer.renderEqualizerWindow(state, skin: skin))
        #expect(image.width == 275 && image.height == 116)
        state.isWindowshade = true
        #expect(SkinRenderer.renderEqualizerWindow(state, skin: skin)?.height == 14)
    }

    @Test func settingsSurviveARoundTrip() throws {
        var settings = EqualizerSettings()
        settings.on = true
        settings.gains[3] = 4.5
        let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
