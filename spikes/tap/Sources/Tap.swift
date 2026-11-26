import AudioToolbox
import CoreAudio
import Foundation

/// One Core Audio process that the HAL knows about.
struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

enum TapError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    var description: String {
        switch self {
        case let .status(what, s): return "\(what) failed: \(s) (\(fourCC(s)))"
        }
    }
}

func fourCC(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let bytes = [24, 16, 8, 0].map { UInt8((u >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: bytes, encoding: .ascii) ?? "?" }
    return "\(s)"
}

private func check(_ what: String, _ s: OSStatus) throws {
    if s != noErr { throw TapError.status(what, s) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) throws -> [T] {
    var addr = address(selector)
    var size: UInt32 = 0
    try check("size \(selector)", AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size))
    let count = Int(size) / MemoryLayout<T>.stride
    if count == 0 { return [] }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { buffer.deallocate() }
    try check("get \(selector)", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer))
    return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: count))
}

private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check("get \(selector)", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value))
    return value
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "" }
    return v.takeRetainedValue() as String
}

enum HAL {
    static func processes() -> [AudioProcess] {
        let ids = (try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                  AudioObjectID.self)) ?? []
        return ids.map { id in
            AudioProcess(object: id,
                         pid: (try? read(id, kAudioProcessPropertyPID, pid_t(0))) ?? -1,
                         bundleID: readString(id, kAudioProcessPropertyBundleID),
                         isRunningOutput: ((try? read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0)
        }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return s == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() throws -> String {
        let device = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                              AudioDeviceID(0))
        return readString(device, kAudioDevicePropertyDeviceUID)
    }
}

/// Levels heard by one tap over a measuring window.
struct Levels {
    var peak: Float = 0
    var sumSquares: Double = 0
    var samples: Int = 0
    var callbacks: Int = 0
    var rms: Float { samples == 0 ? 0 : Float((sumSquares / Double(samples)).squareRoot()) }
    static func dBFS(_ x: Float) -> String { x <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(x)) }
    var summary: String {
        "peak \(Levels.dBFS(peak)) dBFS, rms \(Levels.dBFS(rms)) dBFS, \(samples) samples in \(callbacks) callbacks"
    }
}

/// A process tap (or a global tap) read through a private aggregate device, measured for a while, then torn down.
final class TapMeter {
    enum Target {
        case processes([AudioObjectID])
        case globalExcluding([AudioObjectID])
    }

    private let lock = NSLock()
    private var levels = Levels()

    func measure(_ target: Target, seconds: Double, muted: Bool = false) throws -> Levels {
        let description: CATapDescription
        switch target {
        case let .processes(ids): description = CATapDescription(stereoMixdownOfProcesses: ids)
        case let .globalExcluding(ids): description = CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        }
        description.name = "TapSpike"
        description.isPrivate = true
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tap))
        defer { AudioHardwareDestroyProcessTap(tap) }

        let format = try read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw TapError.status("unexpected tap format \(format)", -1) }

        let aggregateUID = UUID().uuidString
        let outputUID = try HAL.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapSpike",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        defer { AudioHardwareDestroyAggregateDevice(device) }

        lock.lock(); levels = Levels(); lock.unlock()
        var proc: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "tapspike.io")
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                      self?.accumulate(input)
                  })
        defer { if let proc { AudioDeviceDestroyIOProcID(device, proc) } }
        try check("AudioDeviceStart", AudioDeviceStart(device, proc))
        Thread.sleep(forTimeInterval: seconds)
        AudioDeviceStop(device, proc)

        lock.lock(); defer { lock.unlock() }
        return levels
    }

    private func accumulate(_ input: UnsafePointer<AudioBufferList>) {
        var peak: Float = 0
        var sum: Double = 0
        var n = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            for s in samples {
                let a = abs(s)
                if a > peak { peak = a }
                sum += Double(s) * Double(s)
            }
            n += count
        }
        lock.lock()
        levels.peak = max(levels.peak, peak)
        levels.sumSquares += sum
        levels.samples += n
        levels.callbacks += 1
        lock.unlock()
    }
}
