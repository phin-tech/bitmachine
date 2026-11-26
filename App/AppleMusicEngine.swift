import BitMachineKit
import Foundation
import MusicKit

/// BitMachine's Track, not MusicKit's.
typealias Track = BitMachineKit.Track

/// Plays Apple Music Tracks through MusicKit, one at a time: MusicKit's queue only ever holds the Track playing
/// (ADR 0001). MusicKit doesn't say when a Track ends, so the engine polls and calls `onEnded`.
@MainActor
final class AppleMusicEngine {
    enum Failure: LocalizedError {
        case notAuthorized
        case notFound
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "BitMachine isn't allowed to use Apple Music"
            case .notFound: "not on Apple Music"
            }
        }
    }

    var onEnded: (() -> Void)?

    private let player = ApplicationMusicPlayer.shared
    /// Songs already fetched (from search or the library), by id, so playing one needn't fetch it again.
    private var songs: [String: Song] = [:]
    private var poll: Timer?
    private var duration: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var hasStarted = false
    /// Paused or stopped by BitMachine, not by reaching the end.
    private var heldByUs = false

    var elapsed: TimeInterval { player.playbackTime }

    // MARK: Authorization

    static var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    @discardableResult
    static func authorize() async -> Bool {
        if isAuthorized { return true }
        return await MusicAuthorization.request() == .authorized
    }

    // MARK: Finding Tracks

    func remember(_ song: Song) { songs[song.id.rawValue] = song }

    static func track(for song: Song) -> Track {
        Track(source: .appleMusic(id: song.id.rawValue), title: song.title, artist: song.artistName,
              album: song.albumTitle ?? "", duration: song.duration)
    }

    /// Searches the Apple Music Catalog for songs.
    func search(_ term: String) async throws -> [Track] {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch is DecodingError {
            // Seen right after MusicKit was set up for the App ID; a retry has always worked.
            try await Task.sleep(for: .seconds(1))
            response = try await request.response()
        }
        response.songs.forEach(remember)
        return response.songs.map(Self.track)
    }

    /// The songs in the user's Apple Music Library, most recently added first.
    func librarySongs(limit: Int = 100) async throws -> [Track] {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.sort(by: \.libraryAddedDate, ascending: false)
        let items = try await request.response().items
        items.forEach(remember)
        return items.map(Self.track)
    }

    // MARK: Browsing the Apple Music Library

    private var libraryArtists: [String: Artist] = [:]
    private var libraryAlbums: [String: Album] = [:]

    /// Every artist in the library, A to Z.
    func artists() async throws -> [BrowseItem] {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        var request = MusicLibraryRequest<Artist>()
        request.limit = 10000
        request.sort(by: \.name, ascending: true)
        let items = try await request.response().items
        items.forEach { libraryArtists[$0.id.rawValue] = $0 }
        return items.map { BrowseItem(id: $0.id.rawValue, name: $0.name) }
    }

    /// An artist's albums in the library, oldest first.
    func albums(ofArtist id: String) async throws -> [BrowseItem] {
        guard let artist = libraryArtists[id] else { return [] }
        var request = MusicLibraryRequest<Album>()
        request.limit = 1000
        request.filter(matching: \.artists, contains: artist)
        // The library's own date sort has no effect, so they're put in order here.
        let items = try await request.response().items.sorted {
            ($0.releaseDate ?? .distantFuture, $0.title) < ($1.releaseDate ?? .distantFuture, $1.title)
        }
        items.forEach { libraryAlbums[$0.id.rawValue] = $0 }
        return items.map { album in
            BrowseItem(id: album.id.rawValue, name: album.title,
                       year: album.releaseDate.map { Calendar.current.component(.year, from: $0) })
        }
    }

    /// An artist's songs in the library, album by album in track order.
    func songs(ofArtist id: String) async throws -> [Track] {
        guard let artist = libraryArtists[id] else { return [] }
        var request = MusicLibraryRequest<Song>()
        request.limit = 5000
        request.filter(matching: \.artists, contains: artist)
        return tracks(inAlbumOrder: Array(try await request.response().items))
    }

    func songs(ofAlbum id: String) async throws -> [Track] {
        guard let album = libraryAlbums[id] else { return [] }
        var request = MusicLibraryRequest<Song>()
        request.limit = 1000
        request.filter(matching: \.albums, contains: album)
        return tracks(inAlbumOrder: Array(try await request.response().items))
    }

    private func tracks(inAlbumOrder songs: [Song]) -> [Track] {
        let order = Dictionary(songs.map { ($0.albumTitle ?? "", $0.releaseDate ?? .distantPast) },
                               uniquingKeysWith: min)
        let sorted = songs.sorted { a, b in
            let da = order[a.albumTitle ?? ""] ?? .distantPast, db = order[b.albumTitle ?? ""] ?? .distantPast
            if da != db { return da < db }
            if a.albumTitle != b.albumTitle { return (a.albumTitle ?? "") < (b.albumTitle ?? "") }
            if a.discNumber != b.discNumber { return (a.discNumber ?? 0) < (b.discNumber ?? 0) }
            return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
        }
        sorted.forEach(remember)
        return sorted.map(Self.track)
    }

    /// Songs in the library matching `term` in title, artist or album.
    func searchLibrary(_ term: String) async throws -> [Track] {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        var request = MusicLibraryRequest<Song>()
        request.limit = 500
        request.filter(text: term)
        let items = try await request.response().items
        items.forEach(remember)
        return items.map(Self.track)
    }

    // MARK: Apple Music Playlists

    private var libraryPlaylists: [String: MusicKit.Playlist] = [:]

    func playlists() async throws -> [BrowseItem] {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.limit = 1000
        request.sort(by: \.name, ascending: true)
        let items = try await request.response().items
        items.forEach { libraryPlaylists[$0.id.rawValue] = $0 }
        return items.map { BrowseItem(id: $0.id.rawValue, name: $0.name) }
    }

    /// An Apple Music Playlist's songs (its music videos are left out).
    func tracks(ofPlaylist id: String) async throws -> (name: String, tracks: [Track]) {
        guard let playlist = libraryPlaylists[id] else { throw Failure.notFound }
        let detailed = try await playlist.with([.tracks])
        let songs: [Song] = (detailed.tracks ?? []).compactMap {
            if case let .song(song) = $0 { return song }
            return nil
        }
        songs.forEach(remember)
        return (playlist.name, songs.map(Self.track))
    }

    /// Makes a new Apple Music Playlist of these Tracks' songs, in order, through the Apple Music API (MusicKit's
    /// own playlist calls aren't available on the Mac). Returns how many songs went in.
    func createPlaylist(named name: String, of tracks: [Track]) async throws -> Int {
        guard await Self.authorize() else { throw Failure.notAuthorized }
        let songs: [[String: String]] = tracks.compactMap {
            guard case let .appleMusic(id) = $0.source else { return nil }
            // Library songs have "i." ids; the rest are the catalog's.
            return ["id": id, "type": id.hasPrefix("i.") ? "library-songs" : "songs"]
        }
        let batches = stride(from: 0, to: songs.count, by: 100).map { Array(songs[$0 ..< min($0 + 100, songs.count)]) }
        let created = try await appleMusicAPI("v1/me/library/playlists", body: [
            "attributes": ["name": name, "description": "Made in BitMachine"],
            "relationships": ["tracks": ["data": batches.first ?? []]],
        ])
        guard batches.count > 1 else { return songs.count }
        guard let id = ((try? JSONSerialization.jsonObject(with: created)) as? [String: Any])
            .flatMap({ ($0["data"] as? [[String: Any]])?.first?["id"] as? String }) else {
            throw Failure.notFound
        }
        for batch in batches.dropFirst() {
            _ = try await appleMusicAPI("v1/me/library/playlists/\(id)/tracks", body: ["data": batch])
        }
        return songs.count
    }

    private func appleMusicAPI(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.music.apple.com/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await MusicDataRequest(urlRequest: request).response().data
    }

    private func song(id: String) async throws -> Song {
        if let song = songs[id] { return song }
        let found: Song?
        if id.hasPrefix("i.") {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            found = try await request.response().items.first
        } else {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            found = try await request.response().items.first
        }
        guard let found else { throw Failure.notFound }
        remember(found)
        return found
    }

    // MARK: Playing

    func play(_ track: Track) async throws {
        guard case let .appleMusic(id) = track.source else { return }
        guard await Self.authorize() else { throw Failure.notAuthorized }
        let song = try await song(id: id)
        stopPolling()
        duration = song.duration ?? track.duration ?? 0
        lastTime = 0
        hasStarted = false
        heldByUs = false
        player.queue = [song]
        try await Self.startPlaying()
        startPolling()
    }

    func pause() {
        heldByUs = true
        player.pause()
    }

    func resume() async throws {
        heldByUs = false
        try await Self.startPlaying()
    }

    /// MusicKit's player isn't Sendable, so its async `play()` runs off the main actor, on the shared player.
    nonisolated private static func startPlaying() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    func stop() {
        heldByUs = true
        stopPolling()
        player.stop()
    }

    func seek(to time: TimeInterval) {
        player.playbackTime = time
        lastTime = time
    }

    private func startPolling() {
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// The Track has ended when MusicKit stops playing it without being asked: near the end, or with an empty queue.
    private func check() {
        let status = player.state.playbackStatus
        let time = player.playbackTime
        if status == .playing {
            hasStarted = true
            lastTime = time
            return
        }
        guard hasStarted, !heldByUs, status != .seekingForward, status != .seekingBackward else { return }
        let nearEnd = duration > 0 && lastTime >= duration - 2
        if nearEnd || player.queue.currentEntry == nil || status == .stopped {
            stopPolling()
            onEnded?()
        }
    }
}
