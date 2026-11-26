import AppKit
import BitMachineKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private let defaultSkin = PlaceholderSkin.make()
    private let player = Player()
    private var main: MainWindowController!
    private var library: LibraryWindowController!
    private var equalizer: EqualizerWindowController!
    private var playlist: PlaylistWindowController!
    private static let playlistOpenKey = "playlistOpen"
    private var radio: RadioWindowController!
    private static let equalizerOpenKey = "equalizerOpen"
    private static let radioOpenKey = "radioOpen"
    private let permissions = PermissionsWindowController()
    let dock = Dock()

    private static let skinKey = "skinPath"
    private static let doubleSizeKey = "doubleSize"

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self
        Fonts.registerBundled()
        let skin = savedSkin() ?? defaultSkin
        main = MainWindowController(skin: skin, player: player)
        library = LibraryWindowController(player: player)
        equalizer = EqualizerWindowController(skin: skin, player: player)
        equalizer.onVisibilityChange = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.equalizer.isVisible, forKey: Self.equalizerOpenKey)
            self.main.redraw()
        }
        playlist = PlaylistWindowController(skin: skin, player: player)
        playlist.onVisibilityChange = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.playlist.isVisible, forKey: Self.playlistOpenKey)
            self.main.redraw()
        }
        dock.register(main.window)
        dock.register(equalizer.window)
        dock.register(playlist.window)
        radio = RadioWindowController(skin: skin, player: player)
        radio.onVisibilityChange = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.radio.isVisible, forKey: Self.radioOpenKey)
        }
        // The Main Window redraws on every Player change; the Radio Window follows along.
        let mainChange = player.onChange
        player.onChange = { [weak self] in
            mainChange?()
            self?.radio.playerChanged()
        }
        player.onPresetsChange = { [weak self] in self?.radio.playerChanged() }
        dock.register(radio.window)
        library.use(skin)
        player.onPlaylistChange = { [weak self] in self?.library.model.refreshPlaylist() }
        main.isDoubleSize = UserDefaults.standard.bool(forKey: Self.doubleSizeKey)
        equalizer.isDoubleSize = main.isDoubleSize
        radio.isDoubleSize = main.isDoubleSize
        main.show()
        playlist.isDoubleSize = main.isDoubleSize
        if UserDefaults.standard.bool(forKey: Self.equalizerOpenKey) { equalizer.show() }
        if UserDefaults.standard.object(forKey: Self.playlistOpenKey) == nil
            || UserDefaults.standard.bool(forKey: Self.playlistOpenKey) { playlist.show() }
        if UserDefaults.standard.bool(forKey: Self.radioOpenKey) { radio.show() }
        permissions.showAtLaunchIfNeeded()
        #if !APP_STORE
        UpdateChecker.shared.start()
        #endif
        #if DEBUG
        // For agents testing playback: BITMACHINE_PLAY="<search>" plays the first Apple Music result at launch.
        // BITMACHINE_STATION="<stream URL>" tunes in to it at launch.
        if let address = ProcessInfo.processInfo.environment["BITMACHINE_STATION"], let url = URL(string: address) {
            player.tune(to: Station(name: url.host() ?? "Station", url: url))
        }
        if let term = ProcessInfo.processInfo.environment["BITMACHINE_PLAY"], !term.isEmpty {
            Task {
                do {
                    let found = try await player.appleMusic.search(term)
                    player.add(Array(found.prefix(2)), play: true)
                } catch {
                    NSLog("BitMachine: BITMACHINE_PLAY failed: \(error)")
                }
            }
        }
        #endif
    }

    func applicationWillTerminate(_: Notification) {
        player.save()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        main.show()
        return false
    }

    // MARK: Skins

    private func savedSkin() -> Skin? {
        guard let path = UserDefaults.standard.string(forKey: Self.skinKey) else { return nil }
        do {
            return try Skin.load(contentsOf: URL(fileURLWithPath: path), fallback: defaultSkin)
        } catch {
            NSLog("BitMachine: couldn't load the saved Skin at \(path): \(error)")
            return nil
        }
    }

    @objc func openSkin(_: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Skin"
        panel.message = "Choose a classic skin (.wsz)"
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(skinAt: url)
    }

    func load(skinAt url: URL) {
        do {
            let skin = try Skin.load(contentsOf: url, fallback: defaultSkin)
            main.use(skin)
            library.use(skin)
            equalizer.use(skin)
            playlist.use(skin)
            radio.use(skin)
            UserDefaults.standard.set(url.path, forKey: Self.skinKey)
        } catch {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” isn't a skin BitMachine can read."
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc func useDefaultSkin(_: Any?) {
        main.use(defaultSkin)
        library.use(defaultSkin)
        equalizer.use(defaultSkin)
        playlist.use(defaultSkin)
        radio.use(defaultSkin)
        UserDefaults.standard.removeObject(forKey: Self.skinKey)
    }

    /// A Skin opened with BitMachine becomes the Skin; music files and folders join the Playlist and play.
    func application(_: NSApplication, open urls: [URL]) {
        let isSkin = { (url: URL) in ["wsz", "zip"].contains(url.pathExtension.lowercased()) }
        if let url = urls.first(where: isSkin) { load(skinAt: url) }
        let music = urls.filter { !isSkin($0) }
        if !music.isEmpty { player.addFiles(music, play: true) }
    }

    // MARK: Windows

    @objc func showPermissions(_: Any?) {
        permissions.show()
    }

    @objc func showLibrary(_: Any?) {
        library.show()
    }

    var isLibraryVisible: Bool { library?.window.isVisible ?? false }

    @objc func toggleEqualizer(_: Any?) {
        if equalizer.isVisible { equalizer.hide() } else { equalizer.show() }
    }

    @objc func togglePlaylist(_: Any?) {
        if playlist.isVisible { playlist.hide() } else { playlist.show() }
    }

    var isPlaylistVisible: Bool { playlist?.isVisible ?? false }

    var isEqualizerVisible: Bool { equalizer?.isVisible ?? false }

    @objc func toggleRadio(_: Any?) {
        if radio.isVisible { radio.hide() } else { radio.show() }
    }

    // MARK: View

    @objc func toggleDoubleSize(_: Any?) {
        let double = !main.isDoubleSize
        dock.scale(by: double ? 2 : 0.5) {
            main.isDoubleSize = double
            equalizer.isDoubleSize = double
            playlist.isDoubleSize = double
            radio.isDoubleSize = double
        }
        UserDefaults.standard.set(main.isDoubleSize, forKey: Self.doubleSizeKey)
    }

    @objc func toggleWindowshade(_: Any?) {
        main.toggleWindowshade()
    }

    var isDoubleSize: Bool { main?.isDoubleSize ?? false }
}
