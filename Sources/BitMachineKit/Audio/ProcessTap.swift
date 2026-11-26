import AudioToolbox
import CoreAudio
import Foundation

/// A process Core Audio knows about.
public struct AudioProcess: Sendable {
    public let object: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
}

/// Core Audio's hardware layer, as much of it as the taps need.
public enum HAL {
    public static func processes() -> [AudioProcess] {
        let ids = (try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                  AudioObjectID.self)) ?? []
        return ids.map { id in
            AudioProcess(object: id,
                         pid: (try? read(id, kAudioProcessPropertyPID, pid_t(0))) ?? -1,
                         bundleID: readString(id, kAudioProcessPropertyBundleID),
                         isRunningOutput: ((try? read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0)
        }
    }

    public static func defaultOutputUID() throws -> String {
        let device = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                              AudioDeviceID(0))
        return readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check("size", AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size))
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check("get", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer))
        return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: count))
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check("get", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value))
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    static func check(_ what: String, _ status: OSStatus) throws {
        if status != noErr { throw ProcessTap.Failure(what: what, status: status) }
    }
}

/// A Core Audio tap on other processes' output, read through a private aggregate device. Muted, it also silences
/// what it taps, so the tapped audio is heard only where BitMachine plays it (ADR 0003). Needs the System Audio
/// Recording permission; without it the tap runs but every sample is zero.
public final class ProcessTap: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let what: String
        public let status: OSStatus
        public var description: String { "\(what) failed (\(status))" }
    }

    /// Called on Core Audio's thread with each buffer: interleaved stereo frames, and the frame count.
    public typealias Handler = @Sendable (_ samples: UnsafePointer<Float>, _ frames: Int) -> Void

    public private(set) var sampleRate: Double = 0
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "tech.phin.bitmachine.tap", qos: .userInteractive)

    /// Taps `processes` (Core Audio process objects), mixed down to stereo, and starts calling `handler`.
    public init(processes: [AudioObjectID], muted: Bool, handler: @escaping Handler) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "BitMachine"
        description.isPrivate = true
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted

        try HAL.check("creating the tap", AudioHardwareCreateProcessTap(description, &tap))
        do {
            let format = try HAL.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            sampleRate = format.mSampleRate
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32
            else { throw Failure(what: "reading the tap's format", status: -1) }

            let outputUID = try HAL.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BitMachine Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try HAL.check("creating the aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))

            let scratch = scratch
            try HAL.check("adding the IO proc", AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, let data = first.mData else { return }
                if interleaved {
                    let channels = max(Int(first.mNumberChannels), 1)
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
                    let samples = data.assumingMemoryBound(to: Float.self)
                    if channels == 2 { handler(samples, frames); return }
                    let n = min(frames, 8192)
                    for f in 0 ..< n {
                        scratch[2 * f] = samples[f * channels]
                        scratch[2 * f + 1] = samples[f * channels + min(1, channels - 1)]
                    }
                    handler(scratch, n)
                } else {
                    let left = data.assumingMemoryBound(to: Float.self)
                    let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
                    let n = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size, 8192)
                    for f in 0 ..< n {
                        scratch[2 * f] = left[f]
                        scratch[2 * f + 1] = right[f]
                    }
                    handler(scratch, n)
                }
            })
            try HAL.check("starting the tap", AudioDeviceStart(device, proc))
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the tap and removes its device; muted audio is heard again.
    public func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
        scratch.deallocate()
    }
}
