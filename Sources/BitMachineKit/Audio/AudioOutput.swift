@preconcurrency import AVFoundation
import Foundation
import os

/// BitMachine's one audio engine: whatever a Source plays comes in here and goes through the same equalizer,
/// balance and volume to the output (ADR 0003). Its inputs are a ring (filled by the Apple Music tap or a
/// Station's decoder) and a file player (Local Files).
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

    /// Everything after the inputs runs at one rate; the input mixer converts each Source to it.
    private static let processing = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private let inputs = AVAudioMixerNode()
    private let filePlayer = AVAudioPlayerNode()

    public init() {
        for (band, frequency) in zip(equalizer.bands, Self.bands) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
        for node in [inputs, equalizer, panner, filePlayer] { engine.attach(node) }
        engine.connect(inputs, to: equalizer, format: Self.processing)
        engine.connect(equalizer, to: panner, format: Self.processing)
        engine.connect(panner, to: engine.mainMixerNode, format: Self.processing)
        engine.mainMixerNode.outputVolume = Float(volume * volume)
        installAnalyzerTap()
    }

    private func ensureRunning() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Pauses the engine when nothing is feeding it.
    private func pauseIfIdle() {
        if source == nil, file == nil { engine.pause() }
    }

    /// Keeps the newest samples for the visualizer.
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

    // MARK: A ring (Apple Music, through the tap)

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
        engine.connect(node, to: inputs, format: format)
        source = node
        try ensureRunning()
    }

    public func stopRing() {
        guard let source else { return }
        engine.disconnectNodeOutput(source)
        engine.detach(source)
        self.source = nil
        pauseIfIdle()
    }

    // MARK: A file (Local Files)

    /// What a file playing is, for the Main Window.
    public struct FileInfo: Sendable {
        public let duration: TimeInterval
        public let sampleRate: Double
        public let channels: Int

        init(_ file: AVAudioFile) {
            duration = Double(file.length) / file.processingFormat.sampleRate
            sampleRate = file.fileFormat.sampleRate
            channels = Int(file.fileFormat.channelCount)
        }

        /// What playing `url` would report, without playing it.
        public init(of url: URL) throws { self.init(try AVAudioFile(forReading: url)) }
    }

    private var file: AVAudioFile?
    /// Where the scheduled part of the file starts, in seconds.
    private var fileOffset: TimeInterval = 0
    /// Bumped by every stop, seek and new file, so a finished callback from before it is ignored.
    private var fileGeneration = 0
    private var onFileEnd: (@Sendable () -> Void)?

    /// Plays an audio file from `time`; `onEnd` is called on the main queue when it has played to the end.
    @discardableResult
    public func playFile(_ url: URL, from time: TimeInterval = 0, onEnd: @escaping @Sendable () -> Void) throws -> FileInfo {
        let file = try AVAudioFile(forReading: url)
        stopFile()
        self.file = file
        onFileEnd = onEnd
        engine.disconnectNodeOutput(filePlayer)
        engine.connect(filePlayer, to: inputs, format: file.processingFormat)
        try ensureRunning()
        schedule(from: time)
        filePlayer.play()
        return FileInfo(file)
    }

    private func schedule(from time: TimeInterval) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let start = min(max(AVAudioFramePosition(time * rate), 0), file.length)
        fileGeneration += 1
        let generation = fileGeneration
        fileOffset = Double(start) / rate
        let remaining = AVAudioFrameCount(max(file.length - start, 0))
        guard remaining > 0 else { return }
        let ended = onFileEnd
        filePlayer.scheduleSegment(file, startingFrame: start, frameCount: remaining, at: nil,
                                   completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.fileGeneration == generation, self.file != nil else { return }
                ended?()
            }
        }
    }

    public var fileElapsed: TimeInterval {
        guard file != nil, let nodeTime = filePlayer.lastRenderTime,
              let playerTime = filePlayer.playerTime(forNodeTime: nodeTime) else { return fileOffset }
        return fileOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Whether a file is loaded (playing or paused).
    public var hasFile: Bool { file != nil }

    public func pauseFile() { filePlayer.pause() }
    public func resumeFile() { filePlayer.play() }

    public func seekFile(to time: TimeInterval) {
        guard file != nil else { return }
        let wasPlaying = filePlayer.isPlaying
        fileGeneration += 1
        filePlayer.stop()
        schedule(from: time)
        if wasPlaying { filePlayer.play() }
    }

    public func stopFile() {
        guard file != nil else { return }
        fileGeneration += 1
        filePlayer.stop()
        file = nil
        onFileEnd = nil
        pauseIfIdle()
    }
}
