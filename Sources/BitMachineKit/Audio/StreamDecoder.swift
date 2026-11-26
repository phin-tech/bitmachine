import AudioToolbox
import Foundation

/// Turns a compressed audio stream (MP3, or AAC in ADTS frames, as internet radio sends it) into stereo Float
/// samples, chunk by chunk, as the bytes arrive. Core Audio's file stream parser finds the packets, and an audio
/// converter decodes them. Not thread-safe: feed it from one queue.
public final class StreamDecoder: @unchecked Sendable {
    public enum Kind: Sendable {
        case mp3, aac

        /// The kind a `Content-Type` names, or nil if it names none BitMachine reads.
        public init?(contentType: String?) {
            let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            switch type {
            case "audio/mpeg", "audio/mp3", "audio/mpeg3", "audio/x-mpeg": self = .mp3
            case "audio/aac", "audio/aacp", "audio/x-aac", "audio/mp4a-latm", "audio/x-hx-aac-adts": self = .aac
            default: return nil
            }
        }

        var fileType: AudioFileTypeID { self == .aac ? kAudioFileAAC_ADTSType : kAudioFileMP3Type }
    }

    public struct DecodeError: LocalizedError {
        public let what: String
        public let status: OSStatus
        public var errorDescription: String? { "\(what) (\(status))" }
    }

    /// Interleaved stereo samples, how many frames there are, and their sample rate.
    public typealias Output = (_ samples: UnsafePointer<Float>, _ frames: Int, _ sampleRate: Double) -> Void

    /// The decoded sample rate, once the stream has said what it is.
    public private(set) var sampleRate: Double?
    /// The stream's channel count as sent, before it's made stereo.
    public private(set) var channels = 2

    private let output: Output
    private var stream: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()

    // Packets waiting to be decoded, and what the converter is being handed now.
    private var waitingBytes = Data()
    private var waitingPackets: [AudioStreamPacketDescription] = []
    private var handing: (bytes: UnsafeMutableRawPointer, packets: UnsafeMutablePointer<AudioStreamPacketDescription>, count: Int)?
    private var handed = false
    private var setupError: DecodeError?

    private static let outputFrames = 4096
    private let outputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: StreamDecoder.outputFrames * 2)
    /// What the input callback returns when it has nothing more for now; not the end of the stream.
    private static let needMore: OSStatus = 0x6E6D_6F72 // 'nmor'

    public init(kind: Kind?, output: @escaping Output) throws {
        self.output = output
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), streamProperty, streamPackets,
                                         kind?.fileType ?? 0, &stream)
        guard status == noErr else { throw DecodeError(what: "Couldn't open the stream parser", status: status) }
    }

    deinit {
        if let stream { AudioFileStreamClose(stream) }
        if let converter { AudioConverterDispose(converter) }
        outputBuffer.deallocate()
    }

    /// Decodes what it can of `data`, calling the output with each stretch of samples.
    public func feed(_ data: Data) throws {
        guard let stream, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress!, [])
        }
        if let setupError { throw setupError }
        guard status == noErr else { throw DecodeError(what: "This stream isn't audio BitMachine can read", status: status) }
        try decodeWaiting()
    }

    // MARK: Parsing

    fileprivate func propertyChanged(_ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets, converter == nil, let stream else { return }
        do { try makeConverter(stream) } catch { setupError = error as? DecodeError }
    }

    private func makeConverter(_ stream: AudioFileStreamID) throws {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &format)
        guard status == noErr else { throw DecodeError(what: "The stream has no audio format", status: status) }
        // HE-AAC ("AAC+") reports its core rate as the data format; the format list has the full one first.
        if let better = Self.firstPlayableFormat(stream) { format = better }
        inputFormat = format
        channels = Int(max(format.mChannelsPerFrame, 1))

        var out = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        status = AudioConverterNew(&format, &out, &made)
        guard status == noErr, let made else { throw DecodeError(what: "Can't decode this stream's audio", status: status) }
        converter = made
        sampleRate = format.mSampleRate

        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
                AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, cookieSize, cookie)
            }
        }
        if channels == 1 {
            // Mono into both ears, not just the left.
            var map: [Int32] = [0, 0]
            AudioConverterSetProperty(made, kAudioConverterChannelMap, UInt32(MemoryLayout<Int32>.size * 2), &map)
        }
    }

    private static func firstPlayableFormat(_ stream: AudioFileStreamID) -> AudioStreamBasicDescription? {
        var size: UInt32 = 0
        guard AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioFormatListItem>.size) else { return nil }
        let count = Int(size) / MemoryLayout<AudioFormatListItem>.size
        var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &size, &list) == noErr else { return nil }
        var index: UInt32 = 0
        var indexSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, size, &list, &indexSize, &index)
            == noErr, Int(index) < count else { return nil }
        return list[Int(index)].mASBD
    }

    fileprivate func received(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer,
                              descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let descriptions else {
            // No descriptions: constant-size packets.
            let size = inputFormat.mBytesPerPacket
            guard size > 0 else { return }
            for i in 0 ..< Int(bytes / size) {
                append(data + i * Int(size), AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: size))
            }
            return
        }
        for i in 0 ..< Int(packets) {
            let d = descriptions[i]
            append(data + Int(d.mStartOffset), d)
        }
    }

    private func append(_ start: UnsafeRawPointer, _ description: AudioStreamPacketDescription) {
        var d = description
        d.mStartOffset = Int64(waitingBytes.count)
        waitingBytes.append(start.assumingMemoryBound(to: UInt8.self), count: Int(description.mDataByteSize))
        waitingPackets.append(d)
    }

    // MARK: Decoding

    private func decodeWaiting() throws {
        guard let converter, !waitingPackets.isEmpty else { return }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(waitingBytes.count, 1), alignment: 16)
        waitingBytes.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: waitingBytes.count)
        let packets = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: waitingPackets.count)
        packets.initialize(from: waitingPackets, count: waitingPackets.count)
        handing = (bytes, packets, waitingPackets.count)
        handed = false
        waitingBytes.removeAll(keepingCapacity: true)
        waitingPackets.removeAll(keepingCapacity: true)
        defer {
            bytes.deallocate()
            packets.deallocate()
            handing = nil
        }

        let rate = sampleRate ?? 44100
        while true {
            var frames = UInt32(Self.outputFrames)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: frames * 8, mData: UnsafeMutableRawPointer(outputBuffer)))
            let status = AudioConverterFillComplexBuffer(converter, converterInput,
                                                         Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
            if frames > 0 { output(outputBuffer, Int(frames), rate) }
            if status == Self.needMore || frames == 0 { return }
            guard status == noErr else {
                // A damaged packet: drop what's left of this batch and carry on with the next.
                AudioConverterReset(converter)
                return
            }
        }
    }

    fileprivate func supply(_ count: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>,
                            _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard let handing, !handed else {
            count.pointee = 0
            return Self.needMore
        }
        handed = true
        let last = handing.packets[handing.count - 1]
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = handing.bytes
        data.pointee.mBuffers.mDataByteSize = UInt32(last.mStartOffset) + last.mDataByteSize
        data.pointee.mBuffers.mNumberChannels = inputFormat.mChannelsPerFrame
        descriptions?.pointee = handing.packets
        count.pointee = UInt32(handing.count)
        return noErr
    }
}

private func streamProperty(_ refcon: UnsafeMutableRawPointer, _: AudioFileStreamID, _ property: AudioFileStreamPropertyID,
                            _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    Unmanaged<StreamDecoder>.fromOpaque(refcon).takeUnretainedValue().propertyChanged(property)
}

private func streamPackets(_ refcon: UnsafeMutableRawPointer, _ bytes: UInt32, _ packets: UInt32, _ data: UnsafeRawPointer,
                           _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    Unmanaged<StreamDecoder>.fromOpaque(refcon).takeUnretainedValue()
        .received(bytes: bytes, packets: packets, data: data, descriptions: descriptions)
}

private func converterInput(_: AudioConverterRef, _ count: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>,
                            _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                            _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    Unmanaged<StreamDecoder>.fromOpaque(refcon!).takeUnretainedValue().supply(count, data, descriptions)
}
