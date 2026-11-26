import BitMachineKit
import Foundation

/// Owns the Playlist and what the Main Window shows, and hands the current Track to the engine for its Source
/// (ADR 0001): Apple Music, Local Files, Servers (fetched into a cache, then played as files) and Stations.
@MainActor
final class Player {
    private(set) var playlist = Playlist() {
        didSet {
            onPlaylistChange?()
            playlistObservers.forEach { $0() }
            scheduleSave()
        }
    }

    var state: MainWindowState {
        didSet {
            if state.shuffle != oldValue.shuffle { playlist.shuffle = state.shuffle }
            if state.repeats != oldValue.repeats { playlist.repeats = state.repeats }
            if state.volume != oldValue.volume {
                output.volume = state.volume
                UserDefaults.standard.set(state.volume, forKey: Self.volumeKey)
            }
            if state.balance != oldValue.balance {
                output.balance = state.balance
                UserDefaults.standard.set(state.balance, forKey: Self.balanceKey)
            }
            if state != oldValue {
                onChange?()
                stateObservers.forEach { $0() }
            }
        }
    }

    var onChange: (() -> Void)?
    var onPlaylistChange: (() -> Void)?
    var onEqualizerChange: (() -> Void)?
    private var stateObservers: [() -> Void] = []
    private var playlistObservers: [() -> Void] = []

    /// Also told when what the Main Window shows changes, or the Playlist does.
    func observeState(_ observer: @escaping () -> Void) { stateObservers.append(observer) }
    func observePlaylist(_ observer: @escaping () -> Void) { playlistObservers.append(observer) }

    /// Changes the Playlist's order or contents in place (sort, reverse, crop…); the current Track keeps playing.
    func edit(_ change: (inout Playlist) -> Void) {
        let current = playlist.current
        change(&playlist)
        if state.playback != .stopped, let current, playlist.entry(current) == nil { stop() }
        else if state.playback == .stopped { showCurrent() }
    }

    private static let equalizerKey = "equalizer"

    /// The equalizer, applied to everything BitMachine plays, and saved.
    var equalizer = Player.savedEqualizer() {
        didSet {
            guard equalizer != oldValue else { return }
            applyEqualizer()
            if let data = try? JSONEncoder().encode(equalizer) {
                UserDefaults.standard.set(data, forKey: Self.equalizerKey)
            }
            onEqualizerChange?()
        }
    }

    private static func savedEqualizer() -> EqualizerSettings {
        guard let data = UserDefaults.standard.data(forKey: equalizerKey),
              let settings = try? JSONDecoder().decode(EqualizerSettings.self, from: data) else { return EqualizerSettings() }
        return settings
    }

    private func applyEqualizer() {
        output.equalizerOn = equalizer.on
        output.preamp = equalizer.preamp
        output.gains = equalizer.gains
    }

    let appleMusic = AppleMusicEngine()
    let output = AudioOutput()
    private(set) lazy var router = AppleMusicRouter(output: output)
    private(set) lazy var stations = StationEngine(output: output)
    let directory = StationDirectory()
    let musicFolders = MusicFolders()
    let servers = Servers()

    /// The Stations on the Radio Window's preset buttons, saved.
    var presets = Player.savedPresets() {
        didSet {
            guard presets != oldValue else { return }
            if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: Self.presetsKey) }
            if let entry = playlist.currentEntry { refreshTuner(entry) }
            onPresetsChange?()
        }
    }

    var onPresetsChange: (() -> Void)?
    private static let presetsKey = "radioPresets"

    private static func savedPresets() -> RadioPresets {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode(RadioPresets.self, from: data) else { return RadioPresets() }
        return presets
    }

    /// What the Station playing says is on now (its ICY StreamTitle); nil for anything else.
    private(set) var nowPlaying: String?
    /// When the Station playing was tuned in, for the time display.
    private var tunedIn: Date?
    /// Reconnections since the Station last played for a while.
    private var reconnects = 0
    private var timer: Timer?
    private var visualizerTimer: Timer?
    private let analyzer = SpectrumAnalyzer()
    private var bars = VisualizerBars()
    /// Bumped on every play, so a slow start of an earlier Track can't overwrite a later one.
    private var generation = 0

    init() {
        var state = MainWindowState()
        state.title = "BitMachine - press eject to find music"
        state.stereo = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.volumeKey) != nil { state.volume = defaults.double(forKey: Self.volumeKey) }
        state.balance = defaults.double(forKey: Self.balanceKey)
        self.state = state
        output.balance = state.balance
        restorePlaylist()
        appleMusic.onEnded = { [weak self] in self?.trackEnded() }
        stations.onTitle = { [weak self] title in self?.heard(title: title) }
        stations.onInfo = { [weak self] info in
            guard let self else { return }
            self.state.kbps = info.kbps
            self.state.khz = info.khz
            self.state.stereo = info.stereo
        }
        stations.onDropped = { [weak self] error in self?.stationDropped(error) }
        output.volume = state.volume
        applyEqualizer()
        router.onStateChange = { [weak self] state in
            guard let self, case let .unavailable(reason) = state else { return }
            // Once: the music plays on, but BitMachine's volume and equalizer can't reach it.
            self.state.title = "Volume and EQ are off for Apple Music: \(reason)"
            self.state.titleScroll = 0
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animateVisualizer() }
        }
    }

    /// The analyzer follows what BitMachine's engine plays; paused or stopped, its bars fall away.
    private func animateVisualizer() {
        let hearing = state.playback == .playing && (router.state == .routed || stations.isPlaying || playingFile)
        let levels: [Double]
        if hearing {
            let recent = output.recentSamples()
            levels = analyzer.bars(recent.samples, sampleRate: recent.rate)
        } else {
            levels = []
        }
        bars.update(levels, dt: 1.0 / 30)
        let shown: VisualizerBars? = hearing || !bars.isSilent ? bars : nil
        if shown != state.visualizer { state.visualizer = shown }
    }

    private func tick() {
        var next = state
        next.titleScroll += 5
        if next.playback == .playing, next.seeking == nil {
            next.elapsed = next.isLive ? tunedIn.map { Date().timeIntervalSince($0) } ?? 0
                : playingFile ? output.fileElapsed : appleMusic.elapsed
        }
        if next.tuner != nil { next.tuner?.signal = stations.signal }
        if let tunedIn, Date().timeIntervalSince(tunedIn) > 60 { reconnects = 0 }
        state = next
    }

    // MARK: Saving

    private static let volumeKey = "volume"
    private static let balanceKey = "balance"
    private var saveTask: Task<Void, Never>?

    static var playlistURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMachine/Playlist.json")
    }

    /// The Playlist as it was at the last quit: the same current Track, shuffle and repeat, stopped.
    private func restorePlaylist() {
        guard let data = try? Data(contentsOf: Self.playlistURL),
              var saved = try? JSONDecoder().decode(Playlist.self, from: data) else { return }
        saved.clearUnavailable()
        playlist = saved
        state.shuffle = saved.shuffle
        state.repeats = saved.repeats
        showCurrent()
    }

    /// Saves soon after a change, so a burst of edits is written once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: Self.playlistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(playlist).write(to: Self.playlistURL, options: .atomic)
        } catch {
            NSLog("BitMachine: couldn't save the Playlist: \(error)")
        }
    }

    // MARK: The Playlist

    /// Adds Tracks to the end; with `play`, the first of them starts.
    func add(_ tracks: [Track], play: Bool) {
        let entries = playlist.append(tracks)
        if play, let first = entries.first { self.play(first.id) }
        else if state.playback == .stopped { showCurrent() }
    }

    /// Adds audio files, and the audio files in folders (all the way down), as Local File Tracks; with `play`, the
    /// first of them starts.
    func addFiles(_ urls: [URL], play: Bool) {
        Task {
            let files = await Task.detached { LocalFiles.audioFiles(in: urls) }.value
            guard !files.isEmpty else { return }
            add(await LocalFiles.tracks(for: files), play: play)
        }
    }

    func remove(_ ids: Set<PlaylistEntry.ID>) {
        let wasCurrent = playlist.current.map(ids.contains) ?? false
        playlist.remove(ids)
        if wasCurrent, state.playback != .stopped {
            if playlist.currentEntry != nil { play(playlist.current!) } else { stop() }
        } else if state.playback == .stopped {
            showCurrent()
        }
    }

    func removeAll() {
        stop()
        playlist.removeAll()
        showCurrent()
    }

    func move(_ ids: [PlaylistEntry.ID], to index: Int) { playlist.move(ids, to: index) }

    // MARK: Server Playlists

    /// Opens a Server Playlist: a copy of its Tracks replaces the Playlist, stopped at its first Track.
    func openServerPlaylist(_ id: String, on server: String) async throws {
        let (name, tracks) = try await servers.client(for: server).playlist(id)
        stop()
        playlist.open(tracks, from: ServerPlaylistReference(server: server, id: id, name: name))
        showCurrent()
    }

    /// Saves the Playlist back over the Server Playlist it was opened from: that Server's Tracks, in Playlist order.
    /// Returns how many were saved and how many Tracks from elsewhere were left out.
    func saveToServer() async throws -> (saved: Int, leftOut: Int) {
        guard let reference = playlist.serverPlaylist else { return (0, 0) }
        let songs = playlist.songs(on: reference.server)
        try await servers.client(for: reference.server).replacePlaylist(reference.id, songs: songs)
        return (songs.count, playlist.entries.count - songs.count)
    }

    // MARK: Transport

    func press(_ button: TransportButton) {
        switch button {
        case .play:
            if state.playback == .paused { resume() }
            else if let current = playlist.current { play(current) }
        case .pause:
            switch state.playback {
            case .playing:
                // A Station is live: paused, it lets go of the stream, and Play tunes in again.
                // Bumping the generation lets a Station still connecting go quietly, not as a failure.
                if state.isLive { generation += 1; stations.stop() }
                else if playingFile { output.pauseFile() }
                else { appleMusic.pause() }
                state.playback = .paused
            case .paused: resume()
            case .stopped: break
            }
        case .stop: stop()
        case .next:
            if playlist.advance() { startOrShow() }
        case .previous:
            if state.playback != .stopped, state.elapsed > 3, !state.isLive { seek(to: 0) }
            else if playlist.goBack() { startOrShow() }
        case .eject:
            AppDelegate.shared.showLibrary(nil)
        }
    }

    /// Plays the current entry if something was playing, else just shows it.
    private func startOrShow() {
        if state.playback == .stopped { showCurrent() } else { play(playlist.current!) }
    }

    func play(_ id: PlaylistEntry.ID) {
        if id != playlist.current { reconnects = 0 }
        playlist.select(id)
        guard let entry = playlist.currentEntry else { return }
        generation += 1
        let generation = generation
        show(entry)
        state.playback = .playing
        state.elapsed = 0
        Task {
            do {
                switch entry.track.source {
                case .appleMusic:
                    // One Source at a time feeds the output.
                    stations.stop()
                    output.stopFile()
                    try await appleMusic.play(entry.track)
                    if generation == self.generation { await router.start() }
                case let .station(url):
                    appleMusic.stop()
                    router.stop()
                    output.stopFile()
                    try await stations.play(url)
                    guard generation == self.generation else { return }
                    tunedIn = Date()
                case let .localFile(url):
                    appleMusic.stop()
                    router.stop()
                    stations.stop()
                    try playFile(url, generation: generation)
                case let .server(server, song):
                    appleMusic.stop()
                    router.stop()
                    stations.stop()
                    // The last Track mustn't play on under this one's title while this one is fetched.
                    output.stopFile()
                    let url = try await servers.file(server: server, song: song)
                    guard generation == self.generation else { return }
                    let paused = state.playback == .paused
                    try playFile(url, generation: generation)
                    if paused { output.pauseFile() }
                    readAhead()
                }
                guard generation == self.generation else { return }
                playlist.markUnavailable(entry.id, reason: nil)
            } catch {
                guard generation == self.generation else { return }
                playlist.markUnavailable(entry.id, reason: error.localizedDescription)
                NSLog("BitMachine: couldn't play %@: %@", entry.track.displayTitle, String(describing: error))
                state.title = "Skipped: \(entry.track.displayTitle) (\(error.localizedDescription))"
                if playlist.advance() { play(playlist.current!) } else { stop(keepTitle: true) }
            }
        }
    }

    /// Whether the file player is what's playing (or paused): a Local File, or a Server Track fetched into the cache.
    private var playingFile: Bool { state.playback != .stopped && output.hasFile }

    /// Fetches the next Server Track, so it starts at once.
    private func readAhead() {
        guard let next = playlist.next(), case let .server(server, song) = next.track.source else { return }
        servers.readAhead(server: server, song: song)
    }

    private func playFile(_ url: URL, generation: Int) throws {
        let info = try output.playFile(url) { [weak self] in
            // The output calls back on the main queue.
            MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                self.trackEnded()
            }
        }
        state.duration = info.duration
        state.khz = Int((info.sampleRate / 1000).rounded())
        state.stereo = info.channels > 1
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        state.kbps = info.duration > 0 ? Int((Double(bytes) * 8 / info.duration / 1000).rounded()) : nil
    }

    private func resume() {
        if state.isLive, let current = playlist.current { play(current); return }
        state.playback = .playing
        if output.hasFile { output.resumeFile(); return }
        Task { try? await appleMusic.resume() }
    }

    func stop(keepTitle: Bool = false) {
        generation += 1
        appleMusic.stop()
        router.stop()
        stations.stop()
        output.stopFile()
        tunedIn = nil
        state.playback = .stopped
        state.elapsed = 0
        if !keepTitle { showCurrent() }
    }

    func seek(toFraction fraction: Double) {
        seek(to: fraction * state.duration)
    }

    private func seek(to time: TimeInterval) {
        // A Station is live: there's nowhere to seek to.
        guard !state.isLive else { return }
        if playingFile { output.seekFile(to: time) } else { appleMusic.seek(to: time) }
        state.elapsed = time
    }

    private func trackEnded() {
        if playlist.advance() { play(playlist.current!) } else {
            // The end of the Playlist: back to its first Track, stopped, as classic players do.
            stop()
        }
    }

    private func showCurrent() {
        if let entry = playlist.currentEntry { show(entry) } else {
            state.title = "BitMachine - press eject to find music"
            state.duration = 0
        }
    }

    private func show(_ entry: PlaylistEntry) {
        nowPlaying = nil
        showTitle(entry)
        state.titleScroll = 0
        state.duration = entry.track.duration ?? 0
        // Apple Music streams 256 kbps AAC at 44.1 kHz; a Station says what it sends once it's tuned in.
        state.kbps = entry.track.source.isAppleMusic ? 256 : nil
        state.khz = entry.track.source.isAppleMusic ? 44 : nil
        if entry.track.source.isAppleMusic { state.stereo = true }
        refreshTuner(entry)
    }

    /// "3. Station Name" and, for a Station, its Frequency and what's on: "3. 94.3 FM Groove Salad - Artist - Song".
    private func showTitle(_ entry: PlaylistEntry) {
        let number = (playlist.index(of: entry.id) ?? 0) + 1
        if case let .station(url) = entry.track.source {
            let on = nowPlaying.flatMap { $0.isEmpty ? nil : " - \($0)" } ?? ""
            state.title = "\(number). \(Frequency(for: url)) FM \(entry.track.title)\(on)"
        } else {
            state.title = "\(number). \(entry.track.displayTitle)" + (entry.track.duration.map { " (\(Self.clock($0)))" } ?? "")
        }
    }

    private func refreshTuner(_ entry: PlaylistEntry) {
        guard case let .station(url) = entry.track.source else { state.tuner = nil; return }
        let preset = presets.slot(of: url).map { $0 + 1 }
        state.tuner = TunerReadout(frequency: Frequency(for: url), signal: state.tuner?.signal ?? 0, preset: preset)
    }

    private func heard(title: String) {
        guard let entry = playlist.currentEntry, entry.track.source.isStation else { return }
        nowPlaying = title
        showTitle(entry)
    }

    /// The stream stopped by itself: tune in again, waiting a little longer each time, and after three tries in a
    /// row that don't hold for a minute, stop and say the Station is lost. It stays playable: it may be back later.
    private func stationDropped(_ error: Error?) {
        guard state.playback == .playing, let entry = playlist.currentEntry,
              case let .station(url) = entry.track.source else { return }
        generation += 1
        let generation = generation
        tunedIn = nil
        Task {
            var lastError = error
            while reconnects < 3 {
                reconnects += 1
                state.title = "Reconnecting to \(entry.track.title)…"
                state.titleScroll = 0
                try? await Task.sleep(for: .seconds(Double(reconnects)))
                guard generation == self.generation else { return }
                do {
                    try await stations.play(url)
                    guard generation == self.generation else { return }
                    tunedIn = Date()
                    showTitle(entry)
                    return
                } catch {
                    guard generation == self.generation else { return }
                    lastError = error
                }
            }
            reconnects = 0
            stop(keepTitle: true)
            state.title = "Lost \(entry.track.title)" + (lastError.map { " (\($0.localizedDescription))" } ?? "")
            state.titleScroll = 0
        }
    }

    /// Plays a Station from the Radio Window: adds it to the Playlist (once) and tunes in.
    func tune(to station: Station) {
        if let existing = playlist.entries.first(where: { $0.track.source == .station(station.url) }) {
            play(existing.id)
        } else {
            add([station.track], play: true)
        }
        Task { await directory.countPlay(of: station) }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
