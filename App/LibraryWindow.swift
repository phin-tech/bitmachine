import AppKit
import BitMachineKit
import SwiftUI

/// What the Library Window shows: search results from a Source, and (until the skinned Playlist Window exists) the
/// Playlist itself.
@MainActor
final class LibraryModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case catalog = "Apple Music"
        case library = "My Library"
        var id: String { rawValue }
    }

    @Published var query = ""
    @Published var scope = Scope.catalog
    @Published var results: [Track] = []
    @Published var status = ""
    @Published var isSearching = false
    @Published var entries: [PlaylistEntry] = []
    @Published var current: PlaylistEntry.ID?
    @Published var colors = PlaylistColors.standard

    let player: Player
    private var searchTask: Task<Void, Never>?

    init(player: Player) {
        self.player = player
        refreshPlaylist()
    }

    func refreshPlaylist() {
        entries = player.playlist.entries
        current = player.playlist.current
    }

    func search() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        let scope = scope
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }
            do {
                switch scope {
                case .catalog:
                    guard !term.isEmpty else { results = []; status = ""; return }
                    results = try await player.appleMusic.search(term)
                case .library:
                    let all = try await player.appleMusic.librarySongs(limit: 500)
                    results = term.isEmpty ? all : all.filter {
                        $0.title.localizedCaseInsensitiveContains(term) || $0.artist.localizedCaseInsensitiveContains(term)
                            || $0.album.localizedCaseInsensitiveContains(term)
                    }
                }
                status = results.isEmpty ? "Nothing found" : "\(results.count) songs"
            } catch is CancellationError {
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func add(_ tracks: [Track], play: Bool) {
        player.add(tracks, play: play || player.state.playback == .stopped && entries.isEmpty)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var selectedResults = Set<Int>()
    @State private var selectedEntries = Set<PlaylistEntry.ID>()

    private var text: Color { Color(cgColor: model.colors.normal.cgColor) }
    private var currentText: Color { Color(cgColor: model.colors.current.cgColor) }
    private var background: Color { Color(cgColor: model.colors.normalBackground.cgColor) }
    private var selection: Color { Color(cgColor: model.colors.selectedBackground.cgColor) }
    private let font = Font.system(size: 11, design: .monospaced)

    var body: some View {
        VSplitView {
            VStack(spacing: 6) {
                HStack {
                    Picker("", selection: $model.scope) {
                        ForEach(LibraryModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    TextField(model.scope == .catalog ? "Search Apple Music" : "Filter your library", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.search() }
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                list(count: model.results.count, selection: $selectedResults) { i in
                    let track = model.results[i]
                    return row(track.displayTitle, album: track.album, duration: track.duration, colour: text)
                } open: { indices in
                    model.add(indices.sorted().map { model.results[$0] }, play: true)
                }
                HStack {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add to Playlist") {
                        model.add(selectedResults.sorted().map { model.results[$0] }, play: false)
                    }
                    .disabled(selectedResults.isEmpty)
                }
            }
            .padding(8)
            .frame(minHeight: 200)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Playlist").font(.headline)
                    Spacer()
                    Button("Remove") { model.player.remove(selectedEntries); selectedEntries = [] }
                        .disabled(selectedEntries.isEmpty)
                    Button("Clear") { model.player.removeAll() }.disabled(model.entries.isEmpty)
                }
                List(selection: $selectedEntries) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { i, entry in
                        row("\(i + 1). \(entry.track.displayTitle)", album: entry.unavailable ?? "",
                            duration: entry.track.duration,
                            colour: entry.id == model.current ? currentText : text)
                            .opacity(entry.unavailable == nil ? 1 : 0.45)
                            .listRowBackground(selectedEntries.contains(entry.id) ? selection : background)
                            .tag(entry.id)
                    }
                    .onMove { from, to in
                        model.player.move(from.map { model.entries[$0].id }, to: to)
                    }
                }
                .contextMenu(forSelectionType: PlaylistEntry.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { model.player.play(id) }
                }
                .onDeleteCommand { model.player.remove(selectedEntries); selectedEntries = [] }
                .scrollContentBackground(.hidden)
                .background(background)
            }
            .padding(8)
            .frame(minHeight: 160)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func row(_ title: String, album: String, duration: TimeInterval?, colour: Color) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            Text(album).lineLimit(1).frame(maxWidth: 180, alignment: .trailing).opacity(0.7)
            Text(duration.map(Player.clock) ?? "").frame(width: 44, alignment: .trailing)
        }
        .font(font)
        .foregroundStyle(colour)
    }

    private func list(count: Int, selection: Binding<Set<Int>>, row: @escaping (Int) -> some View,
                      open: @escaping (Set<Int>) -> Void) -> some View {
        List(selection: selection) {
            ForEach(0 ..< count, id: \.self) { i in
                row(i)
                    .listRowBackground(selection.wrappedValue.contains(i) ? self.selection : background)
                    .tag(i)
            }
        }
        .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { open($0) }
        .scrollContentBackground(.hidden)
        .background(background)
    }
}

/// The Library Window: an ordinary window whose contents follow the Skin's Playlist colours.
@MainActor
final class LibraryWindowController {
    let window: NSWindow
    let model: LibraryModel

    init(player: Player) {
        model = LibraryModel(player: player)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Library"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.setFrameAutosaveName("LibraryWindow")
        if !window.setFrameUsingName("LibraryWindow") { window.center() }
    }

    func use(_ skin: Skin) { model.colors = skin.playlistColors }

    func show() {
        window.makeKeyAndOrderFront(nil)
        if model.scope == .library, model.results.isEmpty { model.search() }
    }
}
