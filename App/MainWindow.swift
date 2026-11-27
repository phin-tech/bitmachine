import AppKit
import AVKit
import BitMachineKit

/// A borderless window that can still become key, as every player window must to take clicks and keys.
final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The Main Window: transport, time, title and sliders, drawn entirely from the Skin.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: PlayerWindow
    private let view: MainWindowView
    private let player: Player
    private var skin: Skin

    var isDoubleSize = false {
        didSet { resize() }
    }

    /// Files dropped on the Main Window join the Playlist, and the first of them plays.
    func dropped(_ urls: [URL]) { player.addFiles(urls, play: true) }

    init(skin: Skin, player: Player) {
        self.skin = skin
        self.player = player
        view = MainWindowView()
        window = PlayerWindow(contentRect: CGRect(origin: .zero, size: MainWindowLayout.size),
                              styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "BitMachine"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        view.controller = self
        player.onChange = { [weak self] in self?.redraw() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.redraw() }
        }
        resize()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        redraw()
    }

    func use(_ skin: Skin) {
        self.skin = skin
        redraw()
    }

    func seek(toFraction fraction: Double) { player.seek(toFraction: fraction) }

    var state: MainWindowState {
        get { player.state }
        set { player.state = newValue }
    }

    /// Skin pixels to points.
    var scale: CGFloat { isDoubleSize ? 2 : 1 }

    func redraw() {
        var state = player.state
        state.isFocused = window.isKeyWindow
        state.playlistOpen = AppDelegate.shared?.isPlaylistVisible ?? false
        state.equalizerOpen = AppDelegate.shared?.isEqualizerVisible ?? false
        state.titleInPixelFont = !UserDefaults.standard.bool(forKey: Fonts.titleKey)
        view.title = state.titleInPixelFont || state.isWindowshade
            ? nil : (state.title, state.titleScroll, skin.textColors.text, skin.textColors.background)
        view.image = SkinRenderer.renderMainWindow(state, skin: skin)
        view.scale = scale
        view.needsDisplay = true
    }

    func toggleWindowshade() {
        player.state.isWindowshade.toggle()
        resize()
    }

    /// Fits the window to the Main Window's size at the current scale, keeping its top left where it is.
    private func resize() {
        let size = player.state.isWindowshade ? MainWindowLayout.shadeSize : MainWindowLayout.size
        var frame = window.frame
        let top = frame.maxY
        frame.size = CGSize(width: size.width * scale, height: size.height * scale)
        frame.origin.y = top - frame.height
        AppDelegate.shared.dock.setFrame(window, frame)
        redraw()
    }

    func windowDidBecomeKey(_: Notification) { redraw() }
    func windowDidResignKey(_: Notification) { redraw() }

    // MARK: Controls

    func perform(_ control: MainWindowControl) {
        switch control {
        case .close: NSApp.terminate(nil)
        case .minimize: window.miniaturize(nil)
        case .shade: toggleWindowshade()
        case .options: showOptionsMenu()
        case let .transport(button): player.press(button)
        case .shuffle: player.state.shuffle.toggle()
        case .repeats: player.state.repeats.toggle()
        case .equalizer: AppDelegate.shared.toggleEqualizer(nil)
        case .playlist: AppDelegate.shared.togglePlaylist(nil)
        case .time: player.state.showsRemaining.toggle()
        // While a Station plays, the visualizer area switches between the tuner and the analyzer.
        case .visualizer: if player.state.isLive { player.state.showsTuner.toggle() }
        case .titleBar, .volume, .balance, .position: break
        }
    }

    /// Apple's speaker picker, kept out of sight and opened from menus. With no player of its own it picks the
    /// Mac's output, AirPlay speakers included, and BitMachine follows it.
    private lazy var speakerPicker: AVRoutePickerView = {
        let picker = AVRoutePickerView(frame: .zero)
        picker.alphaValue = 0
        view.addSubview(picker)
        return picker
    }()

    /// Opens the speaker picker under the options button.
    func showSpeakers() {
        let picker = speakerPicker
        picker.frame = CGRect(x: MainWindowLayout.options.minX * scale, y: MainWindowLayout.options.minY * scale,
                              width: MainWindowLayout.options.width * scale, height: MainWindowLayout.options.height * scale)
        window.makeKeyAndOrderFront(nil)
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(button(in:)).first
        }
        button(in: picker)?.performClick(nil)
    }

    private func showOptionsMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Skin…", action: #selector(AppDelegate.openSkin(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Use Default Skin", action: #selector(AppDelegate.useDefaultSkin(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Radio", action: #selector(AppDelegate.toggleRadio(_:)), keyEquivalent: "")
        let double = menu.addItem(withTitle: "Double Size", action: #selector(AppDelegate.toggleDoubleSize(_:)),
                                  keyEquivalent: "")
        double.state = isDoubleSize ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Speakers…", action: #selector(AppDelegate.showSpeakers(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: CGPoint(x: MainWindowLayout.options.minX * scale,
                                                 y: MainWindowLayout.options.maxY * scale), in: view)
    }
}

/// Draws the rendered Main Window at the window's scale, pixel for pixel, and turns the mouse into controls.
@MainActor
final class MainWindowView: NSView {
    weak var controller: MainWindowController?

    // MARK: Dropping files from the Finder

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDrop.types)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDrop.urls(sender)
        guard !urls.isEmpty else { return false }
        controller?.dropped(urls)
        return true
    }
    var image: CGImage?
    var scale: CGFloat = 1
    /// The title to draw in Intel One Mono over the Skin: text, how far it has scrolled (skin pixels), and colours.
    var title: (text: String, scroll: Int, color: RGB, background: RGB)?

    /// The control the mouse went down on.
    private var tracking: MainWindowControl?

    // MARK: Dragging the window, through the Dock

    private var draggingWindow = false

    private func startWindowDrag(_ event: NSEvent) {
        guard let window else { return }
        draggingWindow = true
        AppDelegate.shared.dock.beginDrag(window, at: window.convertPoint(toScreen: event.locationInWindow))
    }

    /// Handles a drag or mouse-up while the window is being dragged; false when it isn't.
    private func continueWindowDrag(_ event: NSEvent, ended: Bool) -> Bool {
        guard draggingWindow, let window else { return false }
        if ended {
            draggingWindow = false
            AppDelegate.shared.dock.endDrag()
        } else {
            AppDelegate.shared.dock.continueDrag(to: window.convertPoint(toScreen: event.locationInWindow))
        }
        return true
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.saveGState()
        // The view is flipped; Core Graphics draws images bottom-up, so flip back for the image.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale,
                                       height: CGFloat(image.height) * scale))
        context.restoreGState()
        if let title { drawTitle(title, in: context) }
    }

    /// The title in a real font, in the band the pixel title uses and a little above and below it, scrolling the
    /// same way when it's too long to fit.
    private func drawTitle(_ title: (text: String, scroll: Int, color: RGB, background: RGB), in context: CGContext) {
        let area = MainWindowLayout.title
        let band = CGRect(x: area.minX * scale, y: (area.minY - 2) * scale, width: area.width * scale, height: 10 * scale)
        context.saveGState()
        context.setFillColor(title.background.cgColor)
        context.fill(band)
        context.clip(to: band)
        let font = NSFont(name: Fonts.intelOneMonoRegular, size: 8 * scale) ?? .monospacedSystemFont(ofSize: 8 * scale, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: title.color.cgColor) ?? .green]
        let text = NSAttributedString(string: title.text, attributes: attributes)
        let width = text.size().width
        let y = band.minY + (band.height - text.size().height) / 2
        if width <= band.width {
            text.draw(at: CGPoint(x: band.minX, y: y))
        } else {
            let gap = NSAttributedString(string: "  ***  ", attributes: attributes).size().width
            let period = width + gap
            let offset = (CGFloat(title.scroll) * scale).truncatingRemainder(dividingBy: period)
            text.draw(at: CGPoint(x: band.minX - offset, y: y))
            text.draw(at: CGPoint(x: band.minX - offset + period, y: y))
        }
        context.restoreGState()
    }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = skinPoint(event)
        let control = MainWindowLayout.control(at: point, windowshade: controller.state.isWindowshade)
        tracking = control
        switch control {
        case .visualizer? where !controller.state.isLive:
            // The analyzer is only a control while a Station plays; otherwise it drags, as it always did.
            window?.performDrag(with: event)
            tracking = nil
        case .titleBar?:
            if event.clickCount == 2 {
                controller.toggleWindowshade()
            } else {
                startWindowDrag(event)
            }
            tracking = nil
        case .volume?, .balance?, .position?:
            controller.state.pressed = control
            slide(control!, to: point)
        case let control?:
            controller.state.pressed = control
        case nil:
            // Anywhere without a control drags the window, as in classic players.
            startWindowDrag(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag(event, ended: false) { return }
        guard let controller, let tracking else { return }
        let point = skinPoint(event)
        switch tracking {
        case .volume, .balance, .position:
            slide(tracking, to: point)
        default:
            // A button shows pressed only while the mouse is still over it.
            let over = MainWindowLayout.control(at: point, windowshade: controller.state.isWindowshade) == tracking
            controller.state.pressed = over ? tracking : nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        if continueWindowDrag(event, ended: true) { return }
        guard let controller, let tracking else { return }
        self.tracking = nil
        let point = skinPoint(event)
        controller.state.pressed = nil
        switch tracking {
        case .position:
            if let seek = controller.state.seeking {
                controller.state.seeking = nil
                controller.seek(toFraction: seek)
            }
        case .volume, .balance:
            break
        default:
            if MainWindowLayout.control(at: point, windowshade: controller.state.isWindowshade) == tracking {
                controller.perform(tracking)
            }
        }
    }

    private func slide(_ control: MainWindowControl, to point: CGPoint) {
        guard let controller else { return }
        switch control {
        case .volume: controller.state.volume = MainWindowLayout.volume(atX: point.x)
        case .balance:
            let value = MainWindowLayout.balance(atX: point.x)
            // Snap to the centre near it, as the classic balance slider does.
            controller.state.balance = abs(value) < 0.08 ? 0 : value
        case .position:
            guard controller.state.playback != .stopped else { return }
            controller.state.seeking = MainWindowLayout.position(atX: point.x)
        default: break
        }
    }
}
