@preconcurrency import AVFoundation
import Foundation
import os

/// BitMachine's one audio engine: whatever a Source plays comes in here and goes through the same equalizer,
/// balance and volume to the output (ADR 0003). For now its only input is a ring that a tap fills.
public final class AudioOutput: @unchecked Sendable {
    /// The classic ten bands, in Hz.
    public static let bands: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    private let panner = AVAudioMixerNode()
    private var source: AVAudioSourceNode?
    /// The newest samples heard (mono, after the equalizer, before the volume), for the visualizer.
    private let recent = OSAllocatedUnfairLock(initialState: (samples: [Float](), rate: 44100.0))

    /// 0...1, heard roughly evenly: the gain is the square of it.
    public var volume: Double = 0.75 {
        didSet { engine.mainMixerNode.outputVolume = Float(volume * volume) }
    }

    /// -1 (left) ... 1 (right)
    public var balance: Double = 0 {
        didSet { panner.pan = Float(balance) }
    }

    public var equalizerOn = false {
        didSet { equalizer.bypass = !equalizerOn }
    }

    /// Each band's gain in dB, -12...12.
    public var gains: [Double] = Array(repeating: 0, count: 10) {
        didSet {
            for (band, gain) in zip(equalizer.bands, gains) { band.gain = Float(min(max(gain, -12), 12)) }
        }
    }

    /// The equalizer's preamp in dB, -12...12.
    public var preamp: Double = 0 {
        didSet { equalizer.globalGain = Float(min(max(preamp, -12), 12)) }
    }

    public init() {
        for (band, frequency) in zip(equalizer.bands, Self.bands) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
        engine.attach(equalizer)
        engine.attach(panner)
        engine.connect(equalizer, to: panner, format: nil)
        engine.connect(panner, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Float(volume * volume)
    }

    /// Keeps the newest samples for the visualizer; installed once something feeds the panner.
    private func installAnalyzerTap() {
        let recent = recent
        panner.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0 ..< count {
                for f in 0 ..< frames { mono[f] += channels[c][f] / Float(count) }
            }
            let rate = buffer.format.sampleRate
            let heard = mono
            recent.withLock { $0 = (Array(($0.samples + heard).suffix(2048)), rate) }
        }
    }

    /// The newest samples heard, mono, and their sample rate.
    public func recentSamples() -> (samples: [Float], rate: Double) {
        recent.withLock { $0 }
    }

    /// Plays what `ring` holds, at its sample rate, until `stopRing`.
    public func play(_ ring: AudioRing, sampleRate: Double) throws {
        stopRing()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let channels = list.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            ring.read(frames: Int(frames), into: channels)
            return noErr
        }
        engine.attach(node)
        // The equalizer can't change sample rate, so it runs at the source's; the mixers after it convert.
        engine.disconnectNodeOutput(equalizer)
        engine.connect(node, to: equalizer, format: format)
        engine.connect(equalizer, to: panner, format: format)
        source = node
        installAnalyzerTap()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    public func stopRing() {
        guard let source else { return }
        panner.removeTap(onBus: 0)
        engine.disconnectNodeOutput(source)
        engine.detach(source)
        self.source = nil
        engine.pause()
    }
}
