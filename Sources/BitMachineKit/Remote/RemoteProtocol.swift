import Foundation

/// What a Controller and a Host say to each other. One message per frame, as JSON. A message this copy can't read
/// (from a newer BitMachine) is skipped, not fatal, so the two Macs needn't update together.
public enum RemoteMessage: Codable, Equatable, Sendable {
    // Handshake, in the clear.
    /// Controller → Host: connect, as a Controller paired before.
    case hello(Hello)
    /// Controller → Host: pair, with the Controller's half of the key agreement.
    case pairRequest(Hello, publicKey: Data)
    /// Host → Controller: the Host's half; the Host now shows a Pairing Code.
    case pairChallenge(hostID: String, publicKey: Data)
    /// Controller → Host: proof the Controller's user typed the Pairing Code.
    case pairProof(Data)
    /// Host → Controller: paired, with the Host's own proof of the code.
    case paired(Data)
    /// Host → Controller: the Host's nonce, and its proof it holds the Controller's key.
    case challenge(hostID: String, nonce: Data, proof: Data)
    /// Controller → Host: the Controller's proof it holds the key. Everything after is encrypted.
    case proof(Data)
    /// Host → Controller, then the connection closes.
    case denied(String)

    // The session, encrypted.
    case command(RemoteCommand)
    case status(RemoteStatus)
    case playlist(Playlist)
    case equalizer(EqualizerSettings)
    /// Something the Host's user should read on the Controller ("2 Local Files were left out").
    case notice(String)

    public struct Hello: Codable, Equatable, Sendable {
        public var version: Int
        public var controllerID: String
        public var name: String
        public var nonce: Data

        public init(version: Int = RemoteMessage.version, controllerID: String, name: String, nonce: Data) {
            self.version = version
            self.controllerID = controllerID
            self.name = name
            self.nonce = nonce
        }
    }

    /// Bumped when a Host and Controller of different versions can no longer work together.
    public static let version = 1
}

/// What a Controller asks the Host to do: the same things the Host's own windows do.
public enum RemoteCommand: Codable, Equatable, Sendable {
    case press(TransportButton)
    case play(PlaylistEntry.ID)
    case seek(fraction: Double)
    case volume(Double)
    case balance(Double)
    case shuffle(Bool)
    case repeats(Bool)
    case equalizer(EqualizerSettings)
    case edit(PlaylistEdit)
    /// Adds Tracks to the end of the Playlist, playing the first of them if asked.
    case add([Track], play: Bool)
    /// Empties the Playlist and fills it with these.
    case replace([Track])
}

/// A change to the Playlist, by entry, so edits made on the Host meanwhile survive.
public enum PlaylistEdit: Codable, Equatable, Sendable {
    case remove(Set<PlaylistEntry.ID>)
    case removeAll
    case move([PlaylistEntry.ID], to: Int)
    case removeUnavailable
    case sort(PlaylistSort)
    case reverse
    case randomize

    public func apply(to playlist: inout Playlist) {
        switch self {
        case let .remove(ids): playlist.remove(ids)
        case .removeAll: playlist.removeAll()
        case let .move(ids, to): playlist.move(ids, to: to)
        case .removeUnavailable: playlist.removeUnavailable()
        case let .sort(order): playlist.sort(by: order.areInOrder)
        case .reverse: playlist.reverse()
        case .randomize: playlist.randomize()
        }
    }
}

public enum PlaylistSort: String, Codable, Sendable {
    case title, artist, album

    public func areInOrder(_ a: Track, _ b: Track) -> Bool {
        switch self {
        case .title: Self.less([a.title], [b.title])
        case .artist: Self.less([a.artist, a.album, a.title], [b.artist, b.album, b.title])
        case .album: Self.less([a.album, a.artist, a.title], [b.album, b.artist, b.title])
        }
    }

    /// Compares field by field, as the Finder would.
    private static func less(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) {
            switch x.localizedStandardCompare(y) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return false
    }
}

/// What the Host's Main Window shows that belongs to the music, not to the window: the Controller shows it as its own.
public struct RemoteStatus: Codable, Equatable, Sendable {
    public var playback: MainWindowState.Playback
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var title: String
    public var kbps: Int?
    public var khz: Int?
    public var stereo: Bool
    public var volume: Double
    public var balance: Double
    public var shuffle: Bool
    public var repeats: Bool
    /// The visualizer as drawn, or nil when it's empty.
    public var bars: [Double]?
    public var peaks: [Double]?

    public init(_ state: MainWindowState) {
        playback = state.playback
        elapsed = state.elapsed
        duration = state.duration
        title = state.title
        kbps = state.kbps
        khz = state.khz
        stereo = state.stereo
        volume = state.volume
        balance = state.balance
        shuffle = state.shuffle
        repeats = state.repeats
        bars = state.visualizer?.bars
        peaks = state.visualizer?.peaks
    }

    /// Copies this onto a Controller's own Main Window state, leaving what's the window's alone.
    public func apply(to state: inout MainWindowState) {
        state.playback = playback
        state.elapsed = elapsed
        state.duration = duration
        if state.title != title { state.titleScroll = 0 }
        state.title = title
        state.kbps = kbps
        state.khz = khz
        state.stereo = stereo
        state.volume = min(max(volume, 0), 1)
        state.balance = min(max(balance, -1), 1)
        state.shuffle = shuffle
        state.repeats = repeats
        state.tuner = nil
        if let bars, let peaks { state.visualizer = VisualizerBars(bars: bars, peaks: peaks) } else { state.visualizer = nil }
    }
}
