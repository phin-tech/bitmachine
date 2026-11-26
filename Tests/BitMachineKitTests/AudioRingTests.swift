import Testing
@testable import BitMachineKit

@Suite struct AudioRingTests {
    /// Reads `frames` frames of both channels.
    private func read(_ ring: AudioRing, _ frames: Int) -> (left: [Float], right: [Float], real: Int) {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        let real = ring.read(frames: frames, into: [left, right])
        return (Array(UnsafeBufferPointer(start: left, count: frames)), Array(UnsafeBufferPointer(start: right, count: frames)), real)
    }

    @Test func framesComeOutInOrderPerChannel() {
        let ring = AudioRing(capacityFrames: 16, prefill: 0)
        ring.write(frames: 4) { f, c in Float(f * 10 + c) }
        let out = read(ring, 4)
        #expect(out.left == [0, 10, 20, 30])
        #expect(out.right == [1, 11, 21, 31])
        #expect(out.real == 4)
    }

    @Test func waitsForThePrefillThenRefillsAfterRunningDry() {
        let ring = AudioRing(capacityFrames: 16, prefill: 4)
        ring.write(frames: 3) { _, _ in 1 }
        #expect(read(ring, 2).real == 0)
        ring.write(frames: 1) { _, _ in 1 }
        let out = read(ring, 6)
        #expect(out.real == 4)
        #expect(out.left == [1, 1, 1, 1, 0, 0])
        ring.write(frames: 2) { _, _ in 1 }
        #expect(read(ring, 2).real == 0)  // ran dry, so it waits for the prefill again
    }

    @Test func overflowDropsTheOldest() {
        let ring = AudioRing(capacityFrames: 4, prefill: 0)
        ring.write(frames: 6) { f, _ in Float(f) }
        #expect(ring.available == 4)
        #expect(read(ring, 4).left == [2, 3, 4, 5])
    }

    @Test func aBacklogIsSkippedSoDelayStaysShort() {
        let ring = AudioRing(capacityFrames: 64, prefill: 4, maxLatency: 8)
        ring.write(frames: 20) { f, _ in Float(f) }
        let out = read(ring, 4)
        #expect(out.left == [16, 17, 18, 19])
        #expect(ring.available == 0)
    }

    @Test func wrapsAroundTheStorage() {
        let ring = AudioRing(capacityFrames: 4, prefill: 0)
        ring.write(frames: 3) { f, _ in Float(f) }
        _ = read(ring, 3)
        ring.write(frames: 3) { f, _ in Float(f + 3) }
        #expect(read(ring, 3).left == [3, 4, 5])
    }
}
