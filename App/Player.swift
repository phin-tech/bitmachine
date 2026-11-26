import BitMachineKit
import Foundation

/// Owns the Playlist and what the Main Window shows, and hands the current Track to the engine for its Source
/// (ADR 0001). Only Apple Music has an engine so far; other Sources' Tracks are marked unavailable for now.
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
        let hearing = state.playback == .playing && router.state == .routed
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
        if next.playback == .playing, next.seeking == nil { next.elapsed = appleMusic.elapsed }
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

    // MARK: Transport

    func press(_ button: TransportButton) {
        switch button {
        case .play:
            if state.playback == .paused { resume() }
            else if let current = playlist.current { play(current) }
        case .pause:
            switch state.playback {
            case .playing: appleMusic.pause(); state.playback = .paused
            case .paused: resume()
            case .stopped: break
            }
        case .stop: stop()
        case .next:
            if playlist.advance() { startOrShow() }
        case .previous:
            if state.playback != .stopped, state.elapsed > 3 { seek(to: 0) }
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
                    try await appleMusic.play(entry.track)
                    if generation == self.generation { await router.start() }
                case .localFile, .server: throw PlayError.noEngine
                }
                guard generation == self.generation else { return }
                playlist.markUnavailable(entry.id, reason: nil)
            } catch {
                guard generation == self.generation else { return }
                playlist.markUnavailable(entry.id, reason: error.localizedDescription)
                state.title = "Skipped: \(entry.track.displayTitle) (\(error.localizedDescription))"
                if playlist.advance() { play(playlist.current!) } else { stop(keepTitle: true) }
            }
        }
    }

    private enum PlayError: LocalizedError {
        case noEngine
        var errorDescription: String? { "BitMachine can't play this kind of Track yet" }
    }

    private func resume() {
        state.playback = .playing
        Task { try? await appleMusic.resume() }
    }

    func stop(keepTitle: Bool = false) {
        generation += 1
        appleMusic.stop()
        router.stop()
        state.playback = .stopped
        state.elapsed = 0
        if !keepTitle { showCurrent() }
    }

    func seek(toFraction fraction: Double) {
        seek(to: fraction * state.duration)
    }

    private func seek(to time: TimeInterval) {
        appleMusic.seek(to: time)
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
        let number = (playlist.index(of: entry.id) ?? 0) + 1
        state.title = "\(number). \(entry.track.displayTitle)" + (entry.track.duration.map { " (\(Self.clock($0)))" } ?? "")
        state.titleScroll = 0
        state.duration = entry.track.duration ?? 0
        // Apple Music streams 256 kbps AAC at 44.1 kHz.
        state.kbps = entry.track.source.isAppleMusic ? 256 : nil
        state.khz = entry.track.source.isAppleMusic ? 44 : nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
