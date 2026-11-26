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
    private static let equalizerOpenKey = "equalizerOpen"
    private let permissions = PermissionsWindowController()

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
        main.onResize = { [weak self] in
            guard let self, self.equalizer.isVisible else { return }
            self.equalizer.dock(below: self.main.window)
        }
        library.use(skin)
        player.onPlaylistChange = { [weak self] in self?.library.model.refreshPlaylist() }
        main.isDoubleSize = UserDefaults.standard.bool(forKey: Self.doubleSizeKey)
        equalizer.isDoubleSize = main.isDoubleSize
        main.show()
        if UserDefaults.standard.bool(forKey: Self.equalizerOpenKey) { equalizer.show(below: main.window) }
        permissions.showAtLaunchIfNeeded()
        #if !APP_STORE
        UpdateChecker.shared.start()
        #endif
        #if DEBUG
        // For agents testing playback: BITMACHINE_PLAY="<search>" plays the first Apple Music result at launch.
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
        UserDefaults.standard.removeObject(forKey: Self.skinKey)
    }

    func application(_: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            load(skinAt: url)
        }
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
        if equalizer.isVisible { equalizer.hide() } else { equalizer.show(below: main.window) }
    }

    var isEqualizerVisible: Bool { equalizer?.isVisible ?? false }

    // MARK: View

    @objc func toggleDoubleSize(_: Any?) {
        main.isDoubleSize.toggle()
        equalizer.isDoubleSize = main.isDoubleSize
        if equalizer.isVisible { equalizer.dock(below: main.window) }
        UserDefaults.standard.set(main.isDoubleSize, forKey: Self.doubleSizeKey)
    }

    @objc func toggleWindowshade(_: Any?) {
        main.toggleWindowshade()
    }

    var isDoubleSize: Bool { main?.isDoubleSize ?? false }
}
