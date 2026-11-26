import AppKit
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

    /// Told after the window changes size, so the windows docked to it can follow.
    var onResize: (() -> Void)?

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
        state.playlistOpen = AppDelegate.shared?.isLibraryVisible ?? false
        state.equalizerOpen = AppDelegate.shared?.isEqualizerVisible ?? false
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
        window.setFrame(frame, display: true)
        redraw()
        onResize?()
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
        case .playlist:
            // Until the skinned Playlist Window exists, the Playlist lives in the Library Window.
            AppDelegate.shared.showLibrary(nil)
        case .time: player.state.showsRemaining.toggle()
        case .titleBar, .volume, .balance, .position: break
        }
    }

    private func showOptionsMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Skin…", action: #selector(AppDelegate.openSkin(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Use Default Skin", action: #selector(AppDelegate.useDefaultSkin(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let double = menu.addItem(withTitle: "Double Size", action: #selector(AppDelegate.toggleDoubleSize(_:)),
                                  keyEquivalent: "")
        double.state = isDoubleSize ? .on : .off
        menu.popUp(positioning: nil, at: CGPoint(x: MainWindowLayout.options.minX * scale,
                                                 y: MainWindowLayout.options.maxY * scale), in: view)
    }
}

/// Draws the rendered Main Window at the window's scale, pixel for pixel, and turns the mouse into controls.
@MainActor
final class MainWindowView: NSView {
    weak var controller: MainWindowController?
    var image: CGImage?
    var scale: CGFloat = 1

    /// The control the mouse went down on.
    private var tracking: MainWindowControl?

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
        case .titleBar?:
            if event.clickCount == 2 {
                controller.toggleWindowshade()
            } else {
                window?.performDrag(with: event)
            }
            tracking = nil
        case .volume?, .balance?, .position?:
            controller.state.pressed = control
            slide(control!, to: point)
        case let control?:
            controller.state.pressed = control
        case nil:
            // Anywhere without a control drags the window, as in classic players.
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
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
