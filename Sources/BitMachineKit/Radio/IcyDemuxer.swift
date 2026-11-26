import Foundation

/// Separates a SHOUTcast/Icecast stream's audio from the metadata woven into it. Asked for with `Icy-MetaData: 1`,
/// the server sends `icy-metaint` audio bytes, then one length byte, then 16 × that many bytes of metadata
/// (`StreamTitle='Artist - Title';`), over and over. Chunks can split anywhere, even inside the metadata.
public struct IcyDemuxer: Sendable {
    /// Audio bytes between metadata blocks; nil when the server sends none.
    public let metaInterval: Int?

    private var audioLeft: Int
    private var metaLeft = 0
    private var expectingLength = false
    private var meta = Data()

    public init(metaInterval: Int?) {
        self.metaInterval = metaInterval.flatMap { $0 > 0 ? $0 : nil }
        audioLeft = self.metaInterval ?? .max
    }

    /// The audio in `chunk`, and the StreamTitle of every metadata block that finished in it ("" when the station
    /// cleared it).
    public mutating func push(_ chunk: Data) -> (audio: Data, titles: [String]) {
        guard let interval = metaInterval else { return (chunk, []) }
        var audio = Data()
        audio.reserveCapacity(chunk.count)
        var titles: [String] = []
        var i = chunk.startIndex
        while i < chunk.endIndex {
            if expectingLength {
                metaLeft = Int(chunk[i]) * 16
                i += 1
                expectingLength = false
                if metaLeft == 0 { audioLeft = interval }
            } else if metaLeft > 0 {
                let n = min(metaLeft, chunk.endIndex - i)
                meta.append(chunk[i ..< i + n])
                i += n
                metaLeft -= n
                if metaLeft == 0 {
                    if let title = Self.streamTitle(in: meta) { titles.append(title) }
                    meta.removeAll(keepingCapacity: true)
                    audioLeft = interval
                }
            } else {
                let n = min(audioLeft, chunk.endIndex - i)
                audio.append(chunk[i ..< i + n])
                i += n
                audioLeft -= n
                if audioLeft == 0 { expectingLength = true }
            }
        }
        return (audio, titles)
    }

    /// The `StreamTitle` in one metadata block. Stations send UTF-8 or Latin-1 without saying which; Latin-1 is
    /// the fallback when the bytes aren't valid UTF-8.
    public static func streamTitle(in block: Data) -> String? {
        let bytes = block.prefix { $0 != 0 }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
              let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        // A title can hold an apostrophe, so it ends at `';` (or the block's end), not at the next quote.
        let end = rest.range(of: "';")?.lowerBound ?? (rest.hasSuffix("'") ? rest.index(before: rest.endIndex) : rest.endIndex)
        return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
    }
}
