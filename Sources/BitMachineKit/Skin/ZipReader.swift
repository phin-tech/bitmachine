import Compression
import Foundation

/// Reads the files of a zip archive into memory. A Skin is untrusted input, so nothing is ever written to disk
/// (no entry can escape a folder), and sizes are capped. Stored and deflated entries only; no zip64, no encryption.
public enum ZipReader {
    public struct Limits: Sendable {
        public var maxEntrySize: Int
        public var maxTotalSize: Int
        public var maxEntries: Int
        public init(maxEntrySize: Int = 16 << 20, maxTotalSize: Int = 64 << 20, maxEntries: Int = 512) {
            self.maxEntrySize = maxEntrySize
            self.maxTotalSize = maxTotalSize
            self.maxEntries = maxEntries
        }
    }

    public enum Failure: Error, Equatable {
        case notAZip
        case unsupported(String)
        case tooLarge
        case corrupt(String)
    }

    /// Every file in the archive, keyed by its path inside it. Folders are left out.
    public static func entries(of data: Data, limits: Limits = Limits()) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let end = findEndOfCentralDirectory(bytes) else { throw Failure.notAZip }
        let count = Int(bytes.u16(end + 10))
        let directoryOffset = Int(bytes.u32(end + 16))
        guard count <= limits.maxEntries else { throw Failure.tooLarge }
        if bytes.u32(end + 16) == 0xFFFF_FFFF || bytes.u16(end + 10) == 0xFFFF { throw Failure.unsupported("zip64") }

        var result: [String: Data] = [:]
        var total = 0
        var p = directoryOffset
        for _ in 0 ..< count {
            guard p + 46 <= bytes.count, bytes.u32(p) == 0x0201_4B50 else { throw Failure.corrupt("central directory") }
            let flags = bytes.u16(p + 8)
            let method = bytes.u16(p + 10)
            let compressedSize = Int(bytes.u32(p + 20))
            let size = Int(bytes.u32(p + 24))
            let nameLength = Int(bytes.u16(p + 28))
            let extraLength = Int(bytes.u16(p + 30))
            let commentLength = Int(bytes.u16(p + 32))
            let localOffset = Int(bytes.u32(p + 42))
            guard p + 46 + nameLength <= bytes.count else { throw Failure.corrupt("name") }
            let name = String(decoding: bytes[(p + 46) ..< (p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue }
            if flags & 1 != 0 { throw Failure.unsupported("encryption") }
            guard size <= limits.maxEntrySize else { throw Failure.tooLarge }
            total += size
            guard total <= limits.maxTotalSize else { throw Failure.tooLarge }

            guard localOffset + 30 <= bytes.count, bytes.u32(localOffset) == 0x0403_4B50 else {
                throw Failure.corrupt("local header")
            }
            let start = localOffset + 30 + Int(bytes.u16(localOffset + 26)) + Int(bytes.u16(localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw Failure.corrupt("entry data") }
            let compressed = bytes[start ..< (start + compressedSize)]

            switch method {
            case 0:
                guard compressedSize == size else { throw Failure.corrupt("stored size") }
                result[name] = Data(compressed)
            case 8:
                result[name] = try inflate(Array(compressed), size: size)
            default:
                throw Failure.unsupported("compression method \(method)")
            }
        }
        return result
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var i = bytes.count - 22
        while i >= lowest {
            if bytes.u32(i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func inflate(_ input: [UInt8], size: Int) throws -> Data {
        if size == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip stores.
                compression_decode_buffer(destination.baseAddress!, size, source.baseAddress!, input.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt("deflate") }
        return Data(output)
    }
}

private extension [UInt8] {
    func u16(_ i: Int) -> UInt16 {
        guard i + 2 <= count else { return 0 }
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
