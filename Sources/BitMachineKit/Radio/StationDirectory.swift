import Foundation

/// The Station Directory: radio-browser.info, a free, community-run list of internet radio stations. It runs on
/// several mirrors, found through `all.api.radio-browser.info`, and asks clients to name themselves in the
/// User-Agent and to report a play (a "click") when a listener picks a station.
public struct StationDirectory: Sendable {
    public static let userAgent = "BitMachine/\(BitMachineVersion.current)"
    static let discovery = URL(string: "https://all.api.radio-browser.info/json/servers")!
    static let fallbackServers = ["de1.api.radio-browser.info", "fi1.api.radio-browser.info", "de2.api.radio-browser.info"]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The most played Stations BitMachine can play.
    public func top(limit: Int = 100) async throws -> [Station] {
        try await fetch { Self.topURL(server: $0, limit: limit) }
    }

    /// Stations whose name or tags match `term`, most played first.
    public func search(_ term: String, limit: Int = 100) async throws -> [Station] {
        async let byName = fetch { Self.searchURL(server: $0, field: "name", term: term, limit: limit) }
        async let byTag = fetch { Self.searchURL(server: $0, field: "tag", term: term, limit: limit) }
        return Self.merge(try await byName, (try? await byTag) ?? [])
    }

    /// Tells the directory a listener picked the Station, as it asks. Failure doesn't matter.
    public func countPlay(of station: Station) async {
        guard let id = station.directoryID, let server = try? await server(),
              let url = URL(string: "https://\(server)/json/url/\(id)") else { return }
        _ = try? await session.data(for: Self.request(url))
    }

    // MARK: Requests

    private func fetch(_ url: (String) -> URL) async throws -> [Station] {
        let (data, response) = try await session.data(for: Self.request(url(try await server())))
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw DirectoryError.status(http.statusCode)
        }
        return try Self.decode(data)
    }

    public enum DirectoryError: LocalizedError {
        case status(Int)
        public var errorDescription: String? {
            if case let .status(code) = self { return "The station directory answered \(code)" }
            return nil
        }
    }

    private static let chosen = ServerChoice()

    /// A mirror, picked once per launch at random, as the directory asks, to spread the load.
    private func server() async throws -> String {
        if let picked = await Self.chosen.server { return picked }
        var servers = Self.fallbackServers
        if let (data, _) = try? await session.data(for: Self.request(Self.discovery)),
           let listed = try? JSONDecoder().decode([Server].self, from: data).map(\.name), !listed.isEmpty {
            servers = Array(Set(listed))
        }
        let picked = servers.randomElement() ?? Self.fallbackServers[0]
        await Self.chosen.set(picked)
        return picked
    }

    private struct Server: Decodable { let name: String }

    private actor ServerChoice {
        var server: String?
        func set(_ s: String) { server = s }
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func topURL(server: String, limit: Int) -> URL {
        var c = URLComponents(string: "https://\(server)/json/stations/topclick/\(limit * 2)")!
        c.queryItems = [URLQueryItem(name: "hidebroken", value: "true")]
        return c.url!
    }

    static func searchURL(server: String, field: String, term: String, limit: Int) -> URL {
        var c = URLComponents(string: "https://\(server)/json/stations/search")!
        c.queryItems = [
            URLQueryItem(name: field, value: term),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
            // Asks for more than it shows: some won't be playable.
            URLQueryItem(name: "limit", value: String(limit * 2)),
        ]
        return c.url!
    }

    // MARK: Decoding

    private struct Listing: Decodable {
        let stationuuid: String?
        let name: String?
        let url_resolved: String?
        let url: String?
        let codec: String?
        let bitrate: Int?
        let hls: Int?
        let tags: String?
        let country: String?
    }

    /// The codecs BitMachine's decoder reads.
    static let playableCodecs: Set<String> = ["MP3", "AAC", "AAC+"]
    /// Playlist files and HLS: they point at a stream rather than being one.
    static let wrapperExtensions: Set<String> = ["pls", "m3u", "m3u8", "asx", "xspf"]

    /// The Stations in a directory listing that BitMachine can play, in its order, each stream once.
    public static func decode(_ data: Data) throws -> [Station] {
        var seen = Set<URL>()
        return try JSONDecoder().decode([Listing].self, from: data).compactMap { listing in
            guard listing.hls != 1,
                  let codec = listing.codec?.uppercased(), playableCodecs.contains(codec),
                  let address = listing.url_resolved.flatMap({ $0.isEmpty ? nil : $0 }) ?? listing.url,
                  let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !wrapperExtensions.contains(url.pathExtension.lowercased()),
                  seen.insert(url).inserted
            else { return nil }
            let name = (listing.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Station(name: name.isEmpty ? url.host() ?? "Station" : name, url: url,
                           directoryID: listing.stationuuid, codec: codec, bitrate: max(listing.bitrate ?? 0, 0),
                           tags: listing.tags ?? "", country: listing.country ?? "")
        }
    }

    /// `first`, then whatever of `second` isn't in it already.
    static func merge(_ first: [Station], _ second: [Station]) -> [Station] {
        var seen = Set(first.map(\.url))
        return first + second.filter { seen.insert($0.url).inserted }
    }
}
