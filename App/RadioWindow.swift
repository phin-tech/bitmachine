import AppKit
import BitMachineKit

/// The Radio Window: finds Stations in the Station Directory and keeps six on preset buttons. Its frame is the
/// Skin's generic window (`gen.bmp`) and its insides use the Skin's Playlist colours, so it follows every Skin.
@MainActor
final class RadioWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: PlayerWindow
    private let view = RadioWindowView()
    private let field = NSTextField()
    private let player: Player
    private var skin: Skin
    private var searchTask: Task<Void, Never>?
    private var loadedOnce = false
    private var hasSavedPlace = false
    private var state = RadioWindowState() {
        didSet { if state != oldValue { redraw() } }
    }

    var isDoubleSize = false {
        didSet { resize() }
    }

    var onVisibilityChange: (() -> Void)?

    init(skin: Skin, player: Player) {
        self.skin = skin
        self.player = player
        window = PlayerWindow(contentRect: CGRect(origin: .zero, size: RadioWindowLayout.size),
                              styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Radio"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        window.setFrameAutosaveName("RadioWindow")
        hasSavedPlace = window.setFrameUsingName("RadioWindow")
        view.controller = self

        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.placeholderString = "Search stations"
        field.delegate = self
        field.target = self
        field.action = #selector(searchFromField)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        view.addSubview(field)

        state.presets = player.presets
        resize()
    }

    var isVisible: Bool { window.isVisible }

    func use(_ skin: Skin) {
        self.skin = skin
        styleField()
        redraw()
    }

    /// Shows it where it was last, or the first time, docked under the Main Window's Dock.
    func show() {
        resize()
        if !hasSavedPlace {
            AppDelegate.shared.dock.placeUnderDock(window)
            hasSavedPlace = true
        }
        window.makeKeyAndOrderFront(nil)
        if !loadedOnce { loadTop() }
        onVisibilityChange?()
    }

    func hide() {
        window.orderOut(nil)
        onVisibilityChange?()
    }

    /// Follows what the Player is doing: which Station plays, and the presets.
    func playerChanged() {
        var playing: URL?
        if player.state.playback != .stopped, case let .station(url)? = player.playlist.currentEntry?.track.source {
            playing = url
        }
        state.playing = playing
        state.presets = player.presets
    }

    var scale: CGFloat { isDoubleSize ? 2 : 1 }

    func redraw() {
        var drawn = state
        drawn.isFocused = window.isKeyWindow
        // Drawn at the screen's resolution, so the text is sharp; the view then draws it one to one.
        let pixels = scale * (window.backingScaleFactor > 0 ? window.backingScaleFactor : 2)
        view.image = SkinRenderer.renderRadioWindow(drawn, skin: skin, scale: pixels)
        view.scale = scale
        view.imageScale = scale / pixels
        view.needsDisplay = true
    }

    private func resize() {
        let size = RadioWindowLayout.size
        var frame = window.frame
        let top = frame.maxY
        frame.size = CGSize(width: size.width * scale, height: size.height * scale)
        frame.origin.y = top - frame.height
        AppDelegate.shared.dock.setFrame(window, frame)
        let r = RadioWindowLayout.search.insetBy(dx: 1, dy: 1)
        // The view is flipped, so skin coordinates map straight across.
        field.frame = CGRect(x: (r.minX + 2) * scale, y: r.minY * scale, width: (r.width - 3) * scale, height: r.height * scale)
        styleField()
        redraw()
    }

    private func styleField() {
        let colors = skin.playlistColors
        field.backgroundColor = NSColor(cgColor: colors.normalBackground.cgColor)
        field.textColor = NSColor(cgColor: colors.normal.cgColor)
        field.font = NSFont(name: colors.font, size: 9 * scale) ?? .systemFont(ofSize: 9 * scale)
        let dim = NSColor(cgColor: colors.normal.cgColor)?.withAlphaComponent(0.5) ?? .secondaryLabelColor
        field.placeholderAttributedString = NSAttributedString(
            string: "Search stations", attributes: [.foregroundColor: dim, .font: field.font as Any])
    }

    func windowDidBecomeKey(_: Notification) { redraw() }
    func windowDidResignKey(_: Notification) { redraw() }
    func windowDidChangeBackingProperties(_: Notification) { redraw() }

    // MARK: Finding Stations

    private func loadTop() {
        loadedOnce = true
        field.stringValue = ""
        load(status: "Most played") { try await $0.top() }
    }

    @objc private func searchFromField() {
        let term = field.stringValue.trimmingCharacters(in: .whitespaces)
        if term.isEmpty { loadTop(); return }
        load(status: "for “\(term)”") { try await $0.search(term) }
    }

    private func load(status: String, _ fetch: @escaping (StationDirectory) async throws -> [Station]) {
        searchTask?.cancel()
        state.status = "Tuning the directory…"
        let directory = player.directory
        searchTask = Task {
            do {
                let found = try await fetch(directory)
                guard !Task.isCancelled else { return }
                state.stations = found
                state.selected = nil
                state.scroll = 0
                state.status = found.isEmpty ? "No stations \(status)"
                    : status == "Most played" ? "Most played: \(found.count) stations" : "\(found.count) stations \(status)"
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                state.status = error.localizedDescription
            }
        }
    }

    // MARK: Controls

    func control(at point: CGPoint) -> RadioControl? { RadioWindowLayout.control(at: point, state: state) }

    func press(_ control: RadioControl?) { state.pressed = control }

    func click(_ control: RadioControl, count: Int) {
        switch control {
        case .close: hide()
        case .top: loadTop()
        case .search: window.makeFirstResponder(field)
        case let .row(i):
            state.selected = i
            if count >= 2 { player.tune(to: state.stations[i]) }
        case let .preset(i):
            // An empty preset button takes the selected Station, as a car radio's does when held.
            if let station = state.presets[i] { player.tune(to: station) }
            else if let selected = state.selected, state.stations.indices.contains(selected) {
                player.presets[i] = state.stations[selected]
            }
        case .titleBar: break
        }
    }

    func scroll(by rows: Int) {
        state.scroll = min(max(state.scroll + rows, 0), state.maxScroll)
    }

    func moveSelection(by step: Int) {
        guard !state.stations.isEmpty else { return }
        let next = min(max((state.selected ?? -1) + step, 0), state.stations.count - 1)
        state.selected = next
        if next < state.scroll { state.scroll = next }
        if next >= state.scroll + RadioWindowLayout.visibleRows { state.scroll = next - RadioWindowLayout.visibleRows + 1 }
    }

    func playSelected() {
        if let i = state.selected, state.stations.indices.contains(i) { player.tune(to: state.stations[i]) }
    }

    /// The right-click menu for a row or a preset button.
    func menu(for control: RadioControl) -> NSMenu? {
        let menu = NSMenu()
        switch control {
        case let .row(i):
            state.selected = i
            let station = state.stations[i]
            menu.addItem(item("Play", { [weak self] in self?.player.tune(to: station) }))
            menu.addItem(item("Add to Playlist", { [weak self] in self?.player.add([station.track], play: false) }))
            menu.addItem(.separator())
            for p in 0 ..< RadioPresets.count {
                let title = "Save as Preset \(p + 1)" + (state.presets[p].map { " (replaces \($0.name))" } ?? "")
                menu.addItem(item(title, { [weak self] in self?.player.presets[p] = station }))
            }
        case let .preset(p):
            if let selected = state.selected, state.stations.indices.contains(selected) {
                let station = state.stations[selected]
                menu.addItem(item("Save “\(station.name)” Here", { [weak self] in self?.player.presets[p] = station }))
            }
            if let current = state.presets[p] {
                menu.addItem(item("Play \(current.name)", { [weak self] in self?.player.tune(to: current) }))
                menu.addItem(item("Clear Preset \(p + 1)", { [weak self] in self?.player.presets[p] = nil }))
            }
        default: return nil
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target // the item keeps its target alive
        return item
    }
}

/// A menu item's action as a closure.
@MainActor
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Draws the rendered Radio Window pixel for pixel and turns the mouse and keys into its controls.
@MainActor
final class RadioWindowView: NSView {
    weak var controller: RadioWindowController?
    var image: CGImage?
    /// Points per skin pixel, for the mouse.
    var scale: CGFloat = 1
    /// Points per image pixel, for drawing.
    var imageScale: CGFloat = 1
    private var tracking: RadioControl?
    private var scrollRemainder: CGFloat = 0

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
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * imageScale,
                                       height: CGFloat(image.height) * imageScale))
        context.restoreGState()
    }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let control = controller.control(at: skinPoint(event))
        switch control {
        case .titleBar?, nil:
            startWindowDrag(event)
            tracking = nil
        case let .row(i)?:
            window?.makeFirstResponder(self)
            controller.click(.row(i), count: event.clickCount)
            tracking = nil
        case let control?:
            tracking = control
            controller.press(control)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag(event, ended: false) { return }
        guard let controller, let tracking else { return }
        controller.press(controller.control(at: skinPoint(event)) == tracking ? tracking : nil)
    }

    override func mouseUp(with event: NSEvent) {
        if continueWindowDrag(event, ended: true) { return }
        guard let controller, let tracking else { return }
        self.tracking = nil
        controller.press(nil)
        if controller.control(at: skinPoint(event)) == tracking { controller.click(tracking, count: event.clickCount) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller, let control = controller.control(at: skinPoint(event)),
              let menu = controller.menu(for: control) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        scrollRemainder -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / (12 * scale) : event.scrollingDeltaY
        let rows = Int(scrollRemainder)
        if rows != 0 {
            scrollRemainder -= CGFloat(rows)
            controller.scroll(by: rows)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch event.keyCode {
        case 125: controller.moveSelection(by: 1)
        case 126: controller.moveSelection(by: -1)
        case 36, 76: controller.playSelected()
        default: super.keyDown(with: event)
        }
    }
}
