import Foundation

/// Where a Track's audio comes from, and how that Source finds it again.
public enum TrackSource: Hashable, Codable, Sendable {
    /// An Apple Music Track, by its MusicKit id: a catalog id (`697195462`) or an Apple Music Library id (`i.…`).
    case appleMusic(id: String)
    case localFile(URL)
    case server(server: String, song: String)
    /// A Station's stream. It never ends and has no duration.
    case station(URL)

    public var isAppleMusic: Bool {
        if case .appleMusic = self { return true }
        return false
    }

    public var isStation: Bool {
        if case .station = self { return true }
        return false
    }

    public var isLocalFile: Bool {
        if case .localFile = self { return true }
        return false
    }
}

/// A Server Playlist, by its Server and its id there.
public struct ServerPlaylistReference: Hashable, Codable, Sendable {
    public var server: String
    public var id: String
    public var name: String

    public init(server: String, id: String, name: String) {
        self.server = server
        self.id = id
        self.name = name
    }
}

/// One playable piece of audio from any Source, with what BitMachine last knew about it, so it can still be shown
/// when its Source can't play it.
public struct Track: Hashable, Codable, Sendable {
    public var source: TrackSource
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?

    public init(source: TrackSource, title: String, artist: String = "", album: String = "", duration: TimeInterval? = nil) {
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// The Track as the Main Window and Playlist Window show it: "Artist - Title".
    public var displayTitle: String { artist.isEmpty ? title : "\(artist) - \(title)" }
}

/// One place in the Playlist. The same Track can be in the Playlist more than once; each place is its own entry.
public struct PlaylistEntry: Hashable, Identifiable, Codable, Sendable {
    public let id: UUID
    public var track: Track
    /// Why the Track's Source can't play it right now; nil when it can. An Unavailable Track keeps its place.
    public var unavailable: String?

    public init(track: Track, id: UUID = UUID()) {
        self.id = id
        self.track = track
    }
}

/// BitMachine's own ordered list of Tracks, from any mix of Sources, that sets what plays next.
public struct Playlist: Equatable, Codable, Sendable {
    public private(set) var entries: [PlaylistEntry] = []
    /// The entry playing, or that would play on Play.
    public private(set) var current: PlaylistEntry.ID?
    public var shuffle = false {
        didSet { if shuffle != oldValue { reshuffle() } }
    }
    public var repeats = false
    /// The Server Playlist this Playlist was opened from, if it was: Save to Server writes back there.
    public var serverPlaylist: ServerPlaylistReference?
    /// The order shuffle plays the entries in, fixed until the Playlist changes or shuffle is turned on again.
    private var shuffleOrder: [PlaylistEntry.ID] = []
    private var seed: UInt64

    public init(seed: UInt64 = UInt64.random(in: 1 ... .max)) {
        self.seed = seed
    }

    public var currentEntry: PlaylistEntry? { current.flatMap(entry) }
    public var isEmpty: Bool { entries.isEmpty }

    public func entry(_ id: PlaylistEntry.ID) -> PlaylistEntry? { entries.first { $0.id == id } }
    public func index(of id: PlaylistEntry.ID) -> Int? { entries.firstIndex { $0.id == id } }

    // MARK: Editing

    /// Adds Tracks at the end, and returns their entries. The first becomes current if nothing was.
    @discardableResult
    public mutating func append(_ tracks: [Track]) -> [PlaylistEntry] {
        let new = tracks.map { PlaylistEntry(track: $0) }
        entries += new
        if current == nil { current = new.first?.id }
        reshuffle()
        return new
    }

    public mutating func remove(_ ids: Set<PlaylistEntry.ID>) {
        guard !ids.isEmpty else { return }
        if let current, ids.contains(current) {
            // The current entry goes: the next one that stays becomes current, or the one before if none.
            let i = index(of: current) ?? 0
            let after = entries[i...].first { !ids.contains($0.id) } ?? entries[..<i].last { !ids.contains($0.id) }
            self.current = after?.id
        }
        entries.removeAll { ids.contains($0.id) }
        reshuffle()
    }

    public mutating func move(_ ids: [PlaylistEntry.ID], to destination: Int) {
        let moving = entries.filter { ids.contains($0.id) }
        let before = entries[..<min(destination, entries.count)].filter { ids.contains($0.id) }.count
        entries.removeAll { ids.contains($0.id) }
        let at = min(max(destination - before, 0), entries.count)
        entries.insert(contentsOf: moving, at: at)
    }

    /// Reorders the entries: sorted, reversed, or randomized. The current entry stays current.
    public mutating func sort(by areInOrder: (Track, Track) -> Bool) {
        entries.sort { areInOrder($0.track, $1.track) }
    }

    public mutating func reverse() { entries.reverse() }

    public mutating func randomize() {
        var rng = SplitMix(seed: seed)
        entries.shuffle(using: &rng)
        seed = rng.next()
    }

    /// Removes every Unavailable Track.
    public mutating func removeUnavailable() {
        remove(Set(entries.filter { $0.unavailable != nil }.map(\.id)))
    }

    /// The total length of the entries with known durations, and whether any duration was unknown.
    public func totalDuration(of ids: Set<PlaylistEntry.ID>? = nil) -> (seconds: TimeInterval, complete: Bool) {
        let chosen = ids.map { ids in entries.filter { ids.contains($0.id) } } ?? entries
        let known = chosen.compactMap(\.track.duration)
        return (known.reduce(0, +), known.count == chosen.count)
    }

    public mutating func removeAll() {
        entries = []
        current = nil
        shuffleOrder = []
        serverPlaylist = nil
    }

    /// Opens a Server Playlist: a copy of its Tracks replaces the Playlist, which remembers where they came from.
    public mutating func open(_ tracks: [Track], from playlist: ServerPlaylistReference) {
        removeAll()
        _ = append(tracks)
        serverPlaylist = playlist
    }

    /// The songs from `server`, in Playlist order: what saving to one of its Server Playlists sends. Other Sources'
    /// Tracks are left out, since that Server can't hold them.
    public func songs(on server: String) -> [String] {
        entries.compactMap {
            guard case let .server(server: id, song: song) = $0.track.source, id == server else { return nil }
            return song
        }
    }

    public mutating func select(_ id: PlaylistEntry.ID) {
        if entry(id) != nil { current = id }
    }

    public mutating func markUnavailable(_ id: PlaylistEntry.ID, reason: String?) {
        guard let i = index(of: id) else { return }
        entries[i].unavailable = reason
    }

    /// Forgets every Unavailable mark, so each Track is tried again (after a relaunch, say).
    public mutating func clearUnavailable() {
        for i in entries.indices { entries[i].unavailable = nil }
    }

    // MARK: Moving through it

    /// The entries in play order: as listed, or in the shuffle order.
    public var playOrder: [PlaylistEntry.ID] { shuffle ? shuffleOrder : entries.map(\.id) }

    /// The next playable entry after the current one, skipping Unavailable Tracks, wrapping only with repeat.
    public func next() -> PlaylistEntry? { step(+1) }

    /// The playable entry before the current one.
    public func previous() -> PlaylistEntry? { step(-1) }

    private func step(_ direction: Int) -> PlaylistEntry? {
        let order = playOrder
        guard !order.isEmpty else { return nil }
        let start = current.flatMap { order.firstIndex(of: $0) } ?? (direction > 0 ? -1 : order.count)
        for offset in 1 ... order.count {
            var i = start + direction * offset
            if i < 0 || i >= order.count {
                guard repeats else { return nil }
                i = (i % order.count + order.count) % order.count
            }
            if let entry = entry(order[i]), entry.unavailable == nil { return entry }
        }
        return nil
    }

    /// Moves current to the next playable entry; false at the end of the Playlist.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let next = next() else { return false }
        current = next.id
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let previous = previous() else { return false }
        current = previous.id
        return true
    }

    private mutating func reshuffle() {
        var ids = entries.map(\.id)
        var rng = SplitMix(seed: seed)
        ids.shuffle(using: &rng)
        // Shuffle starts from the current entry, so turning it on doesn't jump.
        if let current, let i = ids.firstIndex(of: current) { ids.swapAt(0, i) }
        shuffleOrder = ids
        seed = rng.next()
    }
}

/// A small seeded generator, so shuffle is repeatable in tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
