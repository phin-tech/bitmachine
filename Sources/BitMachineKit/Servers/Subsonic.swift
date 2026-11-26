import CryptoKit
import Foundation

/// A Server the user has signed in to. The password is kept apart, in the Keychain.
public struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: URL
    public var username: String

    public init(id: String = UUID().uuidString, name: String, url: URL, username: String) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
    }
}

/// Something a Server said went wrong, or couldn't be understood.
public enum ServerError: LocalizedError, Equatable, Sendable {
    /// The Server's own error, with its Subsonic code (40 is a wrong username or password).
    case server(code: Int, message: String)
    case unreadable
    /// Couldn't reach the Server; carries the host only, never the signed request.
    case unreachable(host: String, reason: String)
    /// Sent something other than audio where audio was asked for.
    case notAudio(String)

    public var errorDescription: String? {
        switch self {
        case .server(40, _): "Wrong username or password"
        case let .server(_, message): message
        case .unreadable: "The Server's answer couldn't be read"
        case let .unreachable(host, reason): "Can't reach \(host): \(reason)"
        case let .notAudio(type): "The Server sent \(type) instead of audio"
        }
    }
}

/// A Server's artists, albums and playlists as BitMachine browses them.
public struct ServerArtist: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct ServerAlbum: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let year: Int?
}

public struct ServerPlaylistSummary: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let songCount: Int
}

/// The parts of a Server song BitMachine needs to fetch it.
public struct ServerSong: Hashable, Sendable {
    public let track: Track
    public let suffix: String
    public let contentType: String
}

/// Talks to a Subsonic-compatible Server (Navidrome and others) over its REST API, signing each request with a
/// salted token rather than sending the password.
public struct SubsonicClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let account: ServerAccount
    private let password: String
    private let transport: Transport
    private let salt: @Sendable () -> String

    public static let apiVersion = "1.16.1"

    public init(account: ServerAccount, password: String,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
                salt: @escaping @Sendable () -> String = { String(UUID().uuidString.prefix(12)) }) {
        self.account = account
        self.password = password
        self.transport = transport
        self.salt = salt
    }

    // MARK: Requests

    /// The signed address of an API method.
    public func url(_ method: String, _ parameters: [(String, String)] = []) -> URL {
        var components = URLComponents(url: endpoint(method), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = signed(parameters)
        return components.url!
    }

    private func endpoint(_ method: String) -> URL { account.url.appendingPathComponent("rest/\(method)") }

    /// The parameters with the sign-in, form-encoded.
    private func signed(_ parameters: [(String, String)]) -> String {
        let salt = salt()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/")
        return ([("u", account.username), ("t", token), ("s", salt), ("v", Self.apiVersion), ("c", "BitMachine"),
                 ("f", "json")] + parameters)
            .map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")="
                + "\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    /// A request with a timeout short enough that skipping past an unreachable Server doesn't stall.
    public func request(_ url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return request
    }

    /// Calls a method; `post` sends the parameters in the body, for lists too long for an address.
    private func call<Body: Decodable>(_ method: String, _ parameters: [(String, String)] = [], post: Bool = false,
                                       as _: Body.Type) async throws -> Body {
        var request = request(post ? endpoint(method) : url(method, parameters))
        if post {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(signed(parameters).utf8)
        }
        let data: Data
        do {
            (data, _) = try await transport(request)
        } catch let error as URLError {
            throw ServerError.unreachable(host: account.url.host ?? account.url.absoluteString,
                                          reason: error.localizedDescription(withoutURL: true))
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<Body>.self, from: data) else {
            if let failed = try? JSONDecoder().decode(Envelope<Empty>.self, from: data), let error = failed.response.error {
                throw ServerError.server(code: error.code, message: error.message ?? "")
            }
            throw ServerError.unreadable
        }
        if let error = envelope.response.error { throw ServerError.server(code: error.code, message: error.message ?? "") }
        guard envelope.response.status == "ok", let body = envelope.response.body else { throw ServerError.unreadable }
        return body
    }

    // MARK: The API

    /// Checks the address and sign-in.
    public func ping() async throws { _ = try await call("ping", as: Empty.self) }

    public func artists() async throws -> [ServerArtist] {
        let body = try await call("getArtists", as: ArtistsBody.self)
        return (body.artists.index ?? []).flatMap { $0.artist ?? [] }.map { ServerArtist(id: $0.id, name: $0.name) }
    }

    public func albums(ofArtist id: String) async throws -> [ServerAlbum] {
        let body = try await call("getArtist", [("id", id)], as: ArtistBody.self)
        return (body.artist.album ?? []).map(\.album)
    }

    public func songs(ofAlbum id: String) async throws -> [Track] {
        let body = try await call("getAlbum", [("id", id)], as: AlbumBody.self)
        return (body.album.song ?? []).map { $0.track(on: account.id) }
    }

    public func search(_ query: String, limit: Int = 200) async throws -> [Track] {
        let body = try await call("search3", [("query", query), ("songCount", String(limit)), ("artistCount", "0"),
                                              ("albumCount", "0")], as: SearchBody.self)
        return (body.searchResult3.song ?? []).map { $0.track(on: account.id) }
    }

    public func song(_ id: String) async throws -> ServerSong {
        let song = try await call("getSong", [("id", id)], as: SongBody.self).song
        return ServerSong(track: song.track(on: account.id), suffix: song.suffix ?? "", contentType: song.contentType ?? "")
    }

    public func playlists() async throws -> [ServerPlaylistSummary] {
        let body = try await call("getPlaylists", as: PlaylistsBody.self)
        return (body.playlists.playlist ?? []).map { ServerPlaylistSummary(id: $0.id, name: $0.name, songCount: $0.songCount ?? 0) }
    }

    public func playlist(_ id: String) async throws -> (name: String, tracks: [Track]) {
        let playlist = try await call("getPlaylist", [("id", id)], as: PlaylistBody.self).playlist
        return (playlist.name, (playlist.entry ?? []).map { $0.track(on: account.id) })
    }

    /// Replaces a Server Playlist's songs with these, in this order.
    public func replacePlaylist(_ id: String, songs: [String]) async throws {
        _ = try await call("createPlaylist", [("playlistId", id)] + songs.map { ("songId", $0) }, post: true,
                           as: Empty.self)
    }

    /// Where to fetch a song's audio: the file as it is, or, for formats Core Audio can't play, an MP3 the Server
    /// makes from it.
    public func streamURL(song: String, transcode: Bool) -> URL {
        url("stream", [("id", song)] + (transcode ? [("format", "mp3"), ("maxBitRate", "320")] : [("format", "raw")]))
    }
}

// MARK: The JSON

private struct Empty: Decodable {}

private struct Envelope<Body: Decodable>: Decodable {
    let response: Response

    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }

    struct Failure: Decodable {
        let code: Int
        let message: String?
    }

    struct Response: Decodable {
        let status: String
        let error: Failure?
        let body: Body?

        private enum Keys: String, CodingKey { case status, error }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            status = try keys.decode(String.self, forKey: .status)
            error = try keys.decodeIfPresent(Failure.self, forKey: .error)
            body = status == "ok" ? try Body(from: decoder) : nil
        }
    }
}

private struct SongJSON: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let suffix: String?
    let contentType: String?

    func track(on server: String) -> Track {
        Track(source: .server(server: server, song: id), title: title ?? "", artist: artist ?? "", album: album ?? "",
              duration: duration)
    }
}

private struct ArtistsBody: Decodable {
    struct Index: Decodable { let artist: [ArtistJSON]? }
    struct Artists: Decodable { let index: [Index]? }
    let artists: Artists
}

private struct ArtistJSON: Decodable {
    let id: String
    let name: String
}

private struct AlbumJSON: Decodable {
    let id: String
    let name: String
    let artist: String?
    let year: Int?
    var album: ServerAlbum { ServerAlbum(id: id, name: name, artist: artist ?? "", year: year) }
}

private struct ArtistBody: Decodable {
    struct Artist: Decodable { let album: [AlbumJSON]? }
    let artist: Artist
}

private struct AlbumBody: Decodable {
    struct Album: Decodable { let song: [SongJSON]? }
    let album: Album
}

private struct SearchBody: Decodable {
    struct Result: Decodable { let song: [SongJSON]? }
    let searchResult3: Result
}

private struct SongBody: Decodable { let song: SongJSON }

private struct PlaylistsBody: Decodable {
    struct Summary: Decodable {
        let id: String
        let name: String
        let songCount: Int?
    }

    struct Playlists: Decodable { let playlist: [Summary]? }
    let playlists: Playlists
}

private struct PlaylistBody: Decodable {
    struct Playlist: Decodable {
        let name: String
        let entry: [SongJSON]?
    }

    let playlist: Playlist
}

private extension URLError {
    /// The error's description without the failing address, which would carry the signed sign-in.
    func localizedDescription(withoutURL _: Bool) -> String {
        switch code {
        case .timedOut: "it took too long to answer"
        case .cannotFindHost: "no such host"
        case .cannotConnectToHost: "nothing is listening there"
        case .notConnectedToInternet: "this Mac is offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            "its secure connection couldn't be trusted"
        default: "network error \(code.rawValue)"
        }
    }
}
