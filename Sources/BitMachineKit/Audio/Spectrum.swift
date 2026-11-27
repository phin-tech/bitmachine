import Accelerate
import Foundation

/// Turns a window of samples into the classic analyzer's 19 bars, each 0...1, with frequencies spaced
/// logarithmically from 40 Hz to 16 kHz, and levels on a decibel scale.
public struct SpectrumAnalyzer {
    public static let barCount = 19
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    public init(size: Int = 1024) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    }

    /// The bars for `samples` (mono, at least `size` of them; the last `size` are used).
    public func bars(_ samples: [Float], sampleRate: Double) -> [Double] {
        guard samples.count >= size else { return Array(repeating: 0, count: Self.barCount) }
        let windowed = vDSP.multiply(Array(samples.suffix(size)), window)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        // A full-scale sine comes out near size/2 after the Hann window's gain of one half; normalise to 1.
        let scale = 4 / Float(size)
        let binWidth = sampleRate / Double(size)
        let low = 40.0, high = min(16000.0, sampleRate / 2)
        return (0 ..< Self.barCount).map { bar in
            let from = low * pow(high / low, Double(bar) / Double(Self.barCount))
            let to = low * pow(high / low, Double(bar + 1) / Double(Self.barCount))
            let first = max(Int(from / binWidth), 1)
            let last = max(min(Int(to / binWidth), magnitudes.count - 1), first)
            let peak = magnitudes[first ... last].max() ?? 0
            let db = 20 * log10(Double(max(peak * scale, 1e-9)))
            // -48 dB is an empty bar, 0 dB a full one.
            return min(max((db + 48) / 48, 0), 1)
        }
    }
}

/// The analyzer as drawn: bars that rise at once and fall gently, and peak marks that hang, then drop.
public struct VisualizerBars: Equatable, Sendable {
    public private(set) var bars = Array(repeating: 0.0, count: SpectrumAnalyzer.barCount)
    public private(set) var peaks = Array(repeating: 0.0, count: SpectrumAnalyzer.barCount)
    private var peakHold = Array(repeating: 0.0, count: SpectrumAnalyzer.barCount)

    public init() {}

    /// Bars as another copy drew them (a Remote Host's), held as they are.
    public init(bars: [Double], peaks: [Double]) {
        let count = SpectrumAnalyzer.barCount
        self.bars = (bars + Array(repeating: 0, count: count)).prefix(count).map { min(max($0, 0), 1) }
        self.peaks = (peaks + Array(repeating: 0, count: count)).prefix(count).map { min(max($0, 0), 1) }
    }

    /// Takes new levels, `dt` seconds after the last.
    public mutating func update(_ levels: [Double], dt: Double) {
        for i in bars.indices {
            let level = i < levels.count ? levels[i] : 0
            bars[i] = max(level, bars[i] - 2.2 * dt)
            if bars[i] >= peaks[i] {
                peaks[i] = bars[i]
                peakHold[i] = 0.4
            } else if peakHold[i] > 0 {
                peakHold[i] -= dt
            } else {
                peaks[i] = max(peaks[i] - 0.9 * dt, bars[i])
            }
        }
    }

    public mutating func clear() { self = VisualizerBars() }

    public var isSilent: Bool { bars.allSatisfy { $0 <= 0 } && peaks.allSatisfy { $0 <= 0 } }
}
