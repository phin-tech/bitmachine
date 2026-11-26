import Foundation
import Testing
@testable import BitMachineKit

@Suite struct SpectrumTests {
    private func sine(_ frequency: Double, amplitude: Float = 1, rate: Double = 48000, count: Int = 1024) -> [Float] {
        (0 ..< count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    @Test func aToneLightsTheBarForItsFrequency() {
        let analyzer = SpectrumAnalyzer()
        let lowBars = analyzer.bars(sine(100), sampleRate: 48000)
        let highBars = analyzer.bars(sine(5000), sampleRate: 48000)
        let lowest = lowBars.indices.max { lowBars[$0] < lowBars[$1] }!
        let highest = highBars.indices.max { highBars[$0] < highBars[$1] }!
        #expect(lowest < 6)
        #expect(highest > 12)
        #expect(lowBars[lowest] > 0.9)
    }

    @Test func silenceIsEmptyAndQuietIsLow() {
        let analyzer = SpectrumAnalyzer()
        #expect(analyzer.bars(Array(repeating: 0, count: 1024), sampleRate: 48000).allSatisfy { $0 == 0 })
        let quiet = analyzer.bars(sine(1000, amplitude: 0.01), sampleRate: 48000).max()!
        #expect(quiet > 0.1 && quiet < 0.8)  // -40 dB
    }

    @Test func barsRiseAtOnceAndFallGently() {
        var vis = VisualizerBars()
        var levels = Array(repeating: 0.0, count: 19)
        levels[3] = 1
        vis.update(levels, dt: 0.033)
        #expect(vis.bars[3] == 1 && vis.peaks[3] == 1)
        vis.update(Array(repeating: 0, count: 19), dt: 0.1)
        #expect(vis.bars[3] < 1 && vis.bars[3] > 0.5)
        #expect(vis.peaks[3] == 1)  // held
        for _ in 0 ..< 60 { vis.update(Array(repeating: 0, count: 19), dt: 0.05) }
        #expect(vis.isSilent)
    }
}
