import Foundation

/// An internet radio stream that BitMachine can play: an Icecast or SHOUTcast stream of MP3 or AAC.
public struct Station: Hashable, Codable, Sendable {
    public var name: String
    /// The stream itself, not a playlist file that points to it.
    public var url: URL
    /// What the directory calls it, if it came from there; used to count plays.
    public var directoryID: String?
    public var codec: String
    /// kbps, as the directory lists it; 0 when unknown.
    public var bitrate: Int
    public var tags: String
    public var country: String

    public init(name: String, url: URL, directoryID: String? = nil, codec: String = "", bitrate: Int = 0,
                tags: String = "", country: String = "") {
        self.name = name
        self.url = url
        self.directoryID = directoryID
        self.codec = codec
        self.bitrate = bitrate
        self.tags = tags
        self.country = country
    }

    /// The Station as a Track for the Playlist. It has no duration: a Station never ends.
    public var track: Track {
        Track(source: .station(url), title: name, album: tags.split(separator: ",").prefix(3).joined(separator: ", "))
    }

    /// The Station's Frequency.
    public var frequency: Frequency { Frequency(for: url) }
}

/// A made-up FM frequency for a Station, so the tuner has something to show: the same stream always gets the same
/// one, from a stable hash of its URL. Two Stations can share a Frequency; it's only for show.
public struct Frequency: Hashable, Sendable, CustomStringConvertible {
    /// In tenths of a MHz, 875 (87.5) ... 1079 (107.9).
    public let tenths: Int

    public static let lowest = 875
    public static let highest = 1079

    public init(tenths: Int) {
        self.tenths = min(max(tenths, Self.lowest), Self.highest)
    }

    public init(for url: URL) {
        // FNV-1a: Swift's own hashing is seeded per launch, and this must stay the same between launches.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        self.init(tenths: Self.lowest + Int(hash % UInt64(Self.highest - Self.lowest + 1)))
    }

    /// Where it sits on the dial, 0 (87.5) ... 1 (107.9).
    public var dialPosition: Double { Double(tenths - Self.lowest) / Double(Self.highest - Self.lowest) }

    /// "94.3"
    public var description: String { "\(tenths / 10).\(tenths % 10)" }
}

/// The six Stations saved on the Radio Window's preset buttons.
public struct RadioPresets: Codable, Equatable, Sendable {
    public static let count = 6
    public private(set) var slots: [Station?] = Array(repeating: nil, count: count)

    public init() {}

    public subscript(_ i: Int) -> Station? {
        get { slots.indices.contains(i) ? slots[i] : nil }
        set { if slots.indices.contains(i) { slots[i] = newValue } }
    }

    /// The preset button (0-based) holding the stream at `url`, if any.
    public func slot(of url: URL) -> Int? { slots.firstIndex { $0?.url == url } }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([Station?].self, forKey: .slots)
        slots = Array((saved + Array(repeating: nil, count: Self.count)).prefix(Self.count))
    }
}
