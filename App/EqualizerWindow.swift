import AppKit
import BitMachineKit

/// The Equalizer Window: preamp and ten band sliders, ON, AUTO and presets, drawn from the Skin. It sits under the
/// Main Window and moves with it (a child window, until real docking).
@MainActor
final class EqualizerWindowController: NSObject, NSWindowDelegate {
    let window: PlayerWindow
    private let view = EqualizerWindowView()
    private let player: Player
    private var skin: Skin
    private var state = EqualizerWindowState() {
        didSet { if state != oldValue { redraw() } }
    }

    var isDoubleSize = false {
        didSet { resize() }
    }

    var onVisibilityChange: (() -> Void)?
    private var hasSavedPlace = false

    init(skin: Skin, player: Player) {
        self.skin = skin
        self.player = player
        window = PlayerWindow(contentRect: CGRect(origin: .zero, size: EqualizerLayout.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.title = "Equalizer"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        view.controller = self
        window.setFrameAutosaveName("EqualizerWindow")
        hasSavedPlace = window.setFrameUsingName("EqualizerWindow")
        state.settings = player.equalizer
        player.onEqualizerChange = { [weak self] in
            guard let self else { return }
            self.state.settings = self.player.equalizer
        }
    }

    var isVisible: Bool { window.isVisible }

    func use(_ skin: Skin) {
        self.skin = skin
        redraw()
    }

    /// Shows it where it was last, or the first time, docked under the Main Window's Dock.
    func show() {
        resize()
        if !hasSavedPlace {
            AppDelegate.shared.dock.placeUnderDock(window)
            hasSavedPlace = true
        }
        window.orderFront(nil)
        onVisibilityChange?()
    }

    func hide() {
        window.orderOut(nil)
        onVisibilityChange?()
    }

    var scale: CGFloat { isDoubleSize ? 2 : 1 }

    func redraw() {
        var drawn = state
        drawn.isFocused = window.isKeyWindow
        view.image = SkinRenderer.renderEqualizerWindow(drawn, skin: skin)
        view.scale = scale
        view.needsDisplay = true
    }

    private func resize() {
        let size = state.isWindowshade ? EqualizerLayout.shadeSize : EqualizerLayout.size
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

    var isWindowshade: Bool { state.isWindowshade }

    func press(_ control: EqualizerControl?) { state.pressed = control }

    func perform(_ control: EqualizerControl) {
        switch control {
        case .close: hide()
        case .shade:
            state.isWindowshade.toggle()
            resize()
            onVisibilityChange?()
        case .on: player.equalizer.on.toggle()
        case .auto: player.equalizer.auto.toggle()
        case .presets: showPresets()
        case .titleBar, .preamp, .band: break
        }
    }

    func slide(_ control: EqualizerControl, toY y: CGFloat) {
        let db = EqualizerLayout.gain(atY: y)
        switch control {
        case .preamp: player.equalizer.preamp = db
        case let .band(i): player.equalizer.gains[i] = db
        default: break
        }
    }

    private func showPresets() {
        let menu = NSMenu()
        for preset in EqualizerSettings.presets {
            let item = menu.addItem(withTitle: preset.name, action: #selector(choosePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.gains
        }
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: "Reset Preamp", action: #selector(resetPreamp), keyEquivalent: "")
        reset.target = self
        menu.popUp(positioning: nil, at: CGPoint(x: EqualizerLayout.presets.minX * scale,
                                                 y: EqualizerLayout.presets.maxY * scale), in: view)
    }

    @objc private func choosePreset(_ item: NSMenuItem) {
        guard let gains = item.representedObject as? [Double] else { return }
        player.equalizer.gains = gains
        player.equalizer.on = true
    }

    @objc private func resetPreamp() { player.equalizer.preamp = 0 }
}

/// Draws the rendered Equalizer Window pixel for pixel and turns the mouse into its controls.
@MainActor
final class EqualizerWindowView: NSView {
    weak var controller: EqualizerWindowController?
    var image: CGImage?
    var scale: CGFloat = 1
    private var tracking: EqualizerControl?

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
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale,
                                       height: CGFloat(image.height) * scale))
    }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = skinPoint(event)
        let control = EqualizerLayout.control(at: point, windowshade: controller.isWindowshade)
        switch control {
        case .titleBar?, nil:
            if event.clickCount == 2, control == .titleBar { controller.perform(.shade) }
            else { startWindowDrag(event) }
            tracking = nil
        case .preamp?, .band?:
            tracking = control
            controller.press(control)
            controller.slide(control!, toY: point.y)
        case let control?:
            tracking = control
            controller.press(control)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag(event, ended: false) { return }
        guard let controller, let tracking else { return }
        let point = skinPoint(event)
        switch tracking {
        case .preamp, .band: controller.slide(tracking, toY: point.y)
        default:
            let over = EqualizerLayout.control(at: point, windowshade: controller.isWindowshade) == tracking
            controller.press(over ? tracking : nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if continueWindowDrag(event, ended: true) { return }
        guard let controller, let tracking else { return }
        self.tracking = nil
        controller.press(nil)
        switch tracking {
        case .preamp, .band: break
        default:
            if EqualizerLayout.control(at: skinPoint(event), windowshade: controller.isWindowshade) == tracking {
                controller.perform(tracking)
            }
        }
    }
}
