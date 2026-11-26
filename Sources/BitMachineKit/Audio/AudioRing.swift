import Foundation
import os

/// Carries audio from one thread to another: a Core Audio tap writes, BitMachine's engine reads. It holds
/// interleaved frames of a fixed channel count. When the reader falls behind, the oldest frames are dropped; when it
/// runs ahead, it gets silence and waits until `prefill` frames have built up again, so playback doesn't crackle.
public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    public let capacity: Int
    public let prefill: Int
    /// The most frames that may wait; beyond it the reader skips ahead to `prefill`, so delay can't build up.
    public let maxLatency: Int

    private var storage: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var primed = false
    private let lock = OSAllocatedUnfairLock()

    public init(capacityFrames: Int, channels: Int = 2, prefill: Int, maxLatency: Int? = nil) {
        self.channels = channels
        capacity = capacityFrames
        self.prefill = min(prefill, capacityFrames)
        self.maxLatency = min(maxLatency ?? capacityFrames, capacityFrames)
        storage = Array(repeating: 0, count: capacityFrames * channels)
    }

    /// Frames waiting to be read.
    public var available: Int {
        lock.lock(); defer { lock.unlock() }
        return writeFrame - readFrame
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        readFrame = 0
        writeFrame = 0
        primed = false
    }

    /// Writes `frames` frames, where `sample(frame, channel)` gives each sample.
    public func write(frames: Int, sample: (Int, Int) -> Float) {
        lock.lock(); defer { lock.unlock() }
        storage.withUnsafeMutableBufferPointer { buffer in
            for f in 0 ..< frames {
                let base = ((writeFrame + f) % capacity) * channels
                for c in 0 ..< channels { buffer[base + c] = sample(f, c) }
            }
        }
        writeFrame += frames
        if writeFrame - readFrame > capacity { readFrame = writeFrame - capacity }
    }

    /// Reads up to `frames` frames into one buffer per channel, filling what it can't with silence. Returns how many
    /// frames were real.
    @discardableResult
    public func read(frames: Int, into channelBuffers: [UnsafeMutablePointer<Float>]) -> Int {
        lock.lock(); defer { lock.unlock() }
        if writeFrame - readFrame > maxLatency { readFrame = writeFrame - prefill }
        let waiting = writeFrame - readFrame
        if !primed, waiting >= prefill { primed = true }
        let count = primed ? min(frames, waiting) : 0
        storage.withUnsafeBufferPointer { buffer in
            for f in 0 ..< count {
                let base = ((readFrame + f) % capacity) * channels
                for (c, out) in channelBuffers.enumerated() { out[f] = buffer[base + min(c, channels - 1)] }
            }
        }
        for out in channelBuffers where count < frames {
            (out + count).initialize(repeating: 0, count: frames - count)
        }
        readFrame += count
        if count < frames { primed = false }
        return count
    }
}
