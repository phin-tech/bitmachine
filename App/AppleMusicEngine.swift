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
