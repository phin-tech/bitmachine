import AppKit
import BitMachineKit

/// The Playlist Window: the Playlist, drawn in the Skin's frame and colours, with its menus and mini transport.
@MainActor
final class PlaylistWindowController: NSObject, NSWindowDelegate {
    let window: PlayerWindow
    private let view = PlaylistWindowView()
    private let player: Player
    private(set) var skin: Skin
    private(set) var state = PlaylistWindowState()
    private(set) var selection = Set<PlaylistEntry.ID>()
    /// Where a shift-click extends from.
    private var anchor: Int?

    private static let sizeKey = "playlistSize"

    var isDoubleSize = false {
        didSet { resize(to: state.size) }
    }

    var onVisibilityChange: (() -> Void)?
    private var hasSavedPlace = false

    init(skin: Skin, player: Player) {
        self.skin = skin
        self.player = player
        window = PlayerWindow(contentRect: CGRect(origin: .zero, size: PlaylistLayout.defaultSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.title = "Playlist"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        view.controller = self
        window.setFrameAutosaveName("PlaylistWindow")
        hasSavedPlace = window.setFrameUsingName("PlaylistWindow")
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            state.size = PlaylistLayout.snapped(NSSizeFromString(saved))
        }
        player.observePlaylist { [weak self] in self?.refresh() }
        player.observeState { [weak self] in self?.refreshTimes() }
        refresh()
    }

    var entries: [PlaylistEntry] { player.playlist.entries }
    var current: PlaylistEntry.ID? { player.playlist.current }
    var isVisible: Bool { window.isVisible }
    var scale: CGFloat { isDoubleSize ? 2 : 1 }

    func use(_ skin: Skin) {
        self.skin = skin
        redraw()
    }

    /// Shows it where it was last, or the first time, docked under the Main Window's Dock.
    func show() {
        resize(to: state.size)
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

    // MARK: Drawing

    private func refresh() {
        selection = selection.filter { id in entries.contains { $0.id == id } }
        state.rowCount = entries.count
        state.scroll = min(state.scroll, PlaylistLayout.maxScroll(rows: entries.count, size: state.size))
        refreshTimes()
    }

    private func refreshTimes() {
        let total = player.playlist.totalDuration()
        let chosen = player.playlist.totalDuration(of: selection)
        state.runningTime = "\(PlaylistLayout.clock(chosen.seconds))/\(PlaylistLayout.clock(total.seconds))\(total.complete ? "" : "+")"
        let playing = player.state
        state.miniTime = playing.playback == .stopped ? "" : PlaylistLayout.clock(playing.elapsed)
        redraw()
    }

    func redraw() {
        var drawn = state
        drawn.isFocused = window.isKeyWindow
        view.image = SkinRenderer.renderPlaylistWindow(drawn, skin: skin)
        view.scale = scale
        view.needsDisplay = true
    }

    func resize(to size: CGSize) {
        state.size = PlaylistLayout.snapped(size)
        UserDefaults.standard.set(NSStringFromSize(state.size), forKey: Self.sizeKey)
        var frame = window.frame
        let top = frame.maxY
        frame.size = CGSize(width: state.size.width * scale, height: state.size.height * scale)
        frame.origin.y = top - frame.height
        AppDelegate.shared.dock.setFrame(window, frame)
        refresh()
    }

    func windowDidBecomeKey(_: Notification) { redraw() }
    func windowDidResignKey(_: Notification) { redraw() }

    // MARK: Selection and the list

    func press(_ control: PlaylistControl?) {
        state.pressed = control
        redraw()
    }

    func scroll(to row: Int) {
        state.scroll = min(max(row, 0), PlaylistLayout.maxScroll(rows: entries.count, size: state.size))
        redraw()
    }

    func click(row: Int, modifiers: NSEvent.ModifierFlags, count: Int) {
        guard entries.indices.contains(row) else {
            selection = []
            refreshTimes()
            return
        }
        let id = entries[row].id
        if count == 2 {
            player.play(id)
            return
        }
        if modifiers.contains(.shift), let anchor {
            let range = min(anchor, row) ... max(anchor, row)
            selection = Set(range.map { entries[$0].id })
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = row
        } else {
            if !selection.contains(id) { selection = [id] }
            anchor = row
        }
        refreshTimes()
    }

    /// Moves the selected entries so the dragged one lands at `row`.
    func drag(from row: Int, to target: Int) {
        guard entries.indices.contains(row), target != row, !selection.isEmpty else { return }
        let ids = entries.map(\.id).filter(selection.contains)
        let destination = target > row ? min(target + 1, entries.count) : max(target, 0)
        player.move(ids, to: destination)
    }

    func moveSelection(by delta: Int, extend: Bool) {
        guard !entries.isEmpty else { return }
        let last = entries.lastIndex { selection.contains($0.id) } ?? -1
        let row = min(max(last + delta, 0), entries.count - 1)
        if extend { selection.insert(entries[row].id) } else { selection = [entries[row].id] }
        anchor = row
        let visible = PlaylistLayout.visibleRows(state.size)
        if row < state.scroll { state.scroll = row }
        if row >= state.scroll + visible { state.scroll = row - visible + 1 }
        refreshTimes()
    }

    func playSelection() {
        if let first = entries.first(where: { selection.contains($0.id) }) { player.play(first.id) }
    }

    func removeSelection() {
        player.remove(selection)
        selection = []
    }

    // MARK: Buttons and menus

    func perform(_ control: PlaylistControl) {
        switch control {
        case .close: hide()
        case let .transport(button): player.press(button)
        case let .menu(menu): show(menu)
        case .shade, .titleBar, .list, .scrollbar, .resize: break
        }
    }

    /// Asks for audio files, or folders of them, and adds them to the end of the Playlist.
    private func chooseFiles(folders: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        if !folders { panel.allowedContentTypes = [.audio] }
        panel.message = folders ? "Add the music in these folders" : "Add these files"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        player.addFiles(panel.urls, play: false)
    }

    func dropped(_ urls: [URL]) { player.addFiles(urls, play: false) }

    private func show(_ which: PlaylistMenu) {
        let menu = NSMenu()
        func item(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        switch which {
        case .add:
            item("Find Music…") { AppDelegate.shared.showLibrary(nil) }
            item("Add Files…") { [weak self] in self?.chooseFiles(folders: false) }
            item("Add Folder…") { [weak self] in self?.chooseFiles(folders: true) }
        case .remove:
            item("Remove Selected", enabled: !selection.isEmpty) { [weak self] in self?.removeSelection() }
            item("Crop to Selection", enabled: !selection.isEmpty) { [weak self] in
                guard let self else { return }
                self.player.remove(Set(self.entries.map(\.id)).subtracting(self.selection))
            }
            item("Remove Unavailable Tracks") { [weak self] in self?.player.edit { $0.removeUnavailable() } }
            menu.addItem(.separator())
            item("Remove All", enabled: !entries.isEmpty) { [weak self] in self?.player.removeAll() }
        case .select:
            item("Select All") { [weak self] in self?.selectAll() }
            item("Select None") { [weak self] in self?.selection = []; self?.refreshTimes() }
            item("Invert Selection") { [weak self] in
                guard let self else { return }
                self.selection = Set(self.entries.map(\.id)).subtracting(self.selection)
                self.refreshTimes()
            }
        case .misc:
            item("Sort by Title") { [weak self] in self?.player.edit { $0.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } } }
            item("Sort by Artist") { [weak self] in
                self?.player.edit { $0.sort { localizedLess([$0.artist, $0.album, $0.title], [$1.artist, $1.album, $1.title]) } }
            }
            item("Sort by Album") { [weak self] in
                self?.player.edit { $0.sort { localizedLess([$0.album, $0.artist, $0.title], [$1.album, $1.artist, $1.title]) } }
            }
            menu.addItem(.separator())
            item("Reverse") { [weak self] in self?.player.edit { $0.reverse() } }
            item("Randomize") { [weak self] in self?.player.edit { $0.randomize() } }
        case .list:
            item("New Playlist", enabled: !entries.isEmpty) { [weak self] in self?.player.removeAll() }
            if let reference = player.playlist.serverPlaylist {
                menu.addItem(.separator())
                item("Save to Server Playlist “\(reference.name)”") { [weak self] in self?.saveToServer() }
            }
            item("Open a Server Playlist…") { AppDelegate.shared.showLibrary(nil) }
        }
        let rect = PlaylistLayout.menu(which, state.size)
        menu.popUp(positioning: nil, at: CGPoint(x: rect.minX * scale, y: rect.minY * scale), in: view)
    }

    private func saveToServer() {
        Task {
            let alert = NSAlert()
            do {
                let (saved, leftOut) = try await player.saveToServer()
                guard leftOut > 0 else { return }
                alert.messageText = "Saved \(saved) songs"
                alert.informativeText = "\(leftOut) Track\(leftOut == 1 ? " isn't" : "s aren't") on that Server, so "
                    + "\(leftOut == 1 ? "it was" : "they were") left out of the Server Playlist. "
                    + "They stay in your Playlist."
            } catch {
                alert.messageText = "Couldn't save to the Server"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }

    func selectAll() {
        selection = Set(entries.map(\.id))
        refreshTimes()
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// Compares key by key, the way Finder sorts names.
private func localizedLess(_ a: [String], _ b: [String]) -> Bool {
    for (x, y) in zip(a, b) {
        let order = x.localizedStandardCompare(y)
        if order != .orderedSame { return order == .orderedAscending }
    }
    return false
}

/// Draws the Playlist Window: the Skin's frame pixel for pixel, then the rows in a real font at full resolution.
@MainActor
final class PlaylistWindowView: NSView {
    weak var controller: PlaylistWindowController?

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

    private var tracking: PlaylistControl?
    private var dragRow: Int?
    private var resizeStart: (mouse: CGPoint, size: CGSize)?

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
        guard let image, let context = NSGraphicsContext.current?.cgContext, let controller else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale,
                                       height: CGFloat(image.height) * scale))
        context.restoreGState()
        drawRows(controller, context)
    }

    private func drawRows(_ controller: PlaylistWindowController, _ context: CGContext) {
        let colors = controller.skin.playlistColors
        let size = controller.state.size
        let list = PlaylistLayout.list(size)
        let area = CGRect(x: list.minX * scale, y: (list.minY - 3) * scale, width: list.width * scale,
                          height: (list.height + 6) * scale)
        context.saveGState()
        context.setFillColor(colors.normalBackground.cgColor)
        context.fill(area)
        context.clip(to: area)
        let fontName = UserDefaults.standard.bool(forKey: Fonts.listsInSkinFontKey) ? colors.font : Fonts.intelOneMonoRegular
        let font = NSFont(name: fontName, size: 9 * scale) ?? NSFont(name: Fonts.intelOneMonoRegular, size: 9 * scale)
            ?? .monospacedSystemFont(ofSize: 9 * scale, weight: .regular)
        let rowHeight = PlaylistLayout.rowHeight * scale
        let entries = controller.entries
        let first = controller.state.scroll
        let rows = PlaylistLayout.visibleRows(size)
        for i in first ..< min(first + rows + 1, entries.count) {
            let entry = entries[i]
            let y = list.minY * scale + CGFloat(i - first) * rowHeight
            let row = CGRect(x: area.minX, y: y, width: area.width, height: rowHeight)
            if controller.selection.contains(entry.id) {
                context.setFillColor(colors.selectedBackground.cgColor)
                context.fill(row)
            }
            var colour = NSColor(cgColor: (entry.id == controller.current ? colors.current : colors.normal).cgColor) ?? .green
            if entry.unavailable != nil { colour = colour.withAlphaComponent(0.45) }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            let duration = NSAttributedString(string: entry.track.duration.map(PlaylistLayout.clock) ?? "", attributes: attributes)
            let durationWidth = duration.size().width
            let textY = y + (rowHeight - duration.size().height) / 2
            duration.draw(at: CGPoint(x: row.maxX - durationWidth - 3 * scale, y: textY))
            let title = NSAttributedString(string: "\(i + 1). \(entry.track.displayTitle)", attributes: attributes)
            let titleRect = CGRect(x: row.minX + 2 * scale, y: textY, width: row.width - durationWidth - 8 * scale,
                                   height: rowHeight)
            title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        context.restoreGState()
    }

    /// The event's point on screen, which stays put while the window resizes under it.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        window?.makeFirstResponder(self)
        let point = skinPoint(event)
        let size = controller.state.size
        let control = PlaylistLayout.control(at: point, size: size)
        tracking = control
        switch control {
        case .titleBar?, nil:
            tracking = nil
            startWindowDrag(event)
        case .list?:
            let row = PlaylistLayout.row(at: point.y, size: size, scroll: controller.state.scroll) ?? -1
            controller.click(row: row, modifiers: event.modifierFlags, count: event.clickCount)
            dragRow = controller.entries.indices.contains(row) ? row : nil
        case .scrollbar?:
            controller.press(.scrollbar)
            controller.scroll(to: PlaylistLayout.scroll(atY: point.y, rows: controller.entries.count, size: size))
        case .resize?:
            resizeStart = (screenPoint(event), size)
        case let control?:
            controller.press(control)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag(event, ended: false) { return }
        guard let controller, let tracking else { return }
        let point = skinPoint(event)
        let size = controller.state.size
        switch tracking {
        case .list:
            guard let from = dragRow,
                  let to = PlaylistLayout.row(at: min(max(point.y, PlaylistLayout.list(size).minY),
                                                      PlaylistLayout.list(size).maxY - 1),
                                              size: size, scroll: controller.state.scroll),
                  to != from, controller.entries.indices.contains(to) else { return }
            controller.drag(from: from, to: to)
            dragRow = to
        case .scrollbar:
            controller.scroll(to: PlaylistLayout.scroll(atY: point.y, rows: controller.entries.count, size: size))
        case .resize:
            guard let start = resizeStart else { return }
            let mouse = screenPoint(event)
            controller.resize(to: CGSize(width: start.size.width + (mouse.x - start.mouse.x) / scale,
                                         height: start.size.height - (mouse.y - start.mouse.y) / scale))
        default:
            let over = PlaylistLayout.control(at: point, size: size) == tracking
            controller.press(over ? tracking : nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if continueWindowDrag(event, ended: true) { return }
        guard let controller, let tracking else { return }
        self.tracking = nil
        dragRow = nil
        resizeStart = nil
        controller.press(nil)
        switch tracking {
        case .list, .scrollbar, .resize: break
        default:
            if PlaylistLayout.control(at: skinPoint(event), size: controller.state.size) == tracking {
                controller.perform(tracking)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        let rows = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY / (PlaylistLayout.rowHeight * scale)
            : -event.scrollingDeltaY
        accumulated += rows
        let whole = Int(accumulated)
        guard whole != 0 else { return }
        accumulated -= CGFloat(whole)
        controller.scroll(to: controller.state.scroll + whole)
    }

    private var accumulated: CGFloat = 0

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch event.keyCode {
        case 51, 117: controller.removeSelection()           // delete, forward delete
        case 36, 76: controller.playSelection()              // return, enter
        case 125: controller.moveSelection(by: 1, extend: event.modifierFlags.contains(.shift))
        case 126: controller.moveSelection(by: -1, extend: event.modifierFlags.contains(.shift))
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                controller.selectAll()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
