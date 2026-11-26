import AppKit
import BitMachineKit
import Combine
import SwiftUI

/// What the Library Window shows: search results from the Apple Music Catalog or Library, the Local Files in the
/// Music Folders by artist and album, or a Server's music by artist and album, its search and its playlists.
@MainActor
final class LibraryModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case catalog = "Apple Music"
        case library = "My Library"
        case files = "My Files"
        case servers = "Servers"
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

    /// In My Files: the artist and album picked ("" for all).
    @Published var artist = "" { didSet { if artist != oldValue { album = ""; refreshFiles() } } }
    @Published var album = "" { didSet { if album != oldValue { refreshFiles() } } }

    let player: Player
    var musicFolders: MusicFolders { player.musicFolders }
    private var searchTask: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

    // MARK: Servers

    /// The Server browsed, and its artist and album picked ("" for none).
    @Published var server = "" { didSet { if server != oldValue { enterServer() } } }
    @Published var serverArtists: [ServerArtist] = []
    @Published var serverAlbums: [ServerAlbum] = []
    @Published var serverPlaylists: [ServerPlaylistSummary] = []
    @Published var serverArtist = "" { didSet { if serverArtist != oldValue { serverAlbum = ""; loadServerAlbums() } } }
    @Published var serverAlbum = "" { didSet { if serverAlbum != oldValue { loadServerSongs() } } }
    var servers: Servers { player.servers }
    private var serverTask: Task<Void, Never>?

    /// Runs a Server request for the Servers tab, showing what goes wrong; a newer one replaces it.
    private func onServer(_ work: @escaping (SubsonicClient) async throws -> Void) {
        serverTask?.cancel()
        guard scope == .servers, !server.isEmpty else { return }
        serverTask = Task {
            isSearching = true
            defer { isSearching = false }
            do {
                try await work(try servers.client(for: server))
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
        }
    }

    /// Shows a Server: its artists and playlists, nothing picked.
    func enterServer() {
        guard scope == .servers else { return }
        if servers.account(server) == nil { server = servers.accounts.first?.id ?? ""; return }
        serverArtist = ""
        serverAlbums = []
        results = []
        status = ""
        onServer { client in
            async let artists = client.artists()
            async let playlists = client.playlists()
            self.serverArtists = try await artists
            self.serverPlaylists = (try? await playlists) ?? []
            self.status = "\(self.serverArtists.count) artists. Pick one, or search."
        }
    }

    private func loadServerAlbums() {
        serverAlbums = []
        results = []
        guard !serverArtist.isEmpty else { return }
        let artist = serverArtist
        onServer { client in
            let albums = try await client.albums(ofArtist: artist)
            self.serverAlbums = albums
            // All the artist's songs, album by album, until one is picked.
            var songs: [Track] = []
            for album in albums { songs += try await client.songs(ofAlbum: album.id) }
            try Task.checkCancellation()
            self.results = songs
            self.status = Self.songs(songs.count)
        }
    }

    private func loadServerSongs() {
        guard !serverAlbum.isEmpty else { loadServerAlbums(); return }
        let album = serverAlbum
        onServer { client in
            self.results = try await client.songs(ofAlbum: album)
            self.status = Self.songs(self.results.count)
        }
    }

    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    func searchServer(_ term: String) {
        guard !term.isEmpty else { return }
        onServer { client in
            self.results = try await client.search(term)
            self.status = self.results.isEmpty ? "Nothing found" : Self.songs(self.results.count)
        }
    }

    /// Opens a Server Playlist in place of the Playlist, asking first if that would replace anything.
    func openServerPlaylist(_ summary: ServerPlaylistSummary) {
        if !player.playlist.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the Playlist with “\(summary.name)”?"
            alert.informativeText = "Its \(summary.songCount) songs take the place of what's in the Playlist now. "
                + "LIST ▸ Save to Server Playlist writes your changes back to the Server."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let server = server
        Task {
            do {
                try await player.openServerPlaylist(summary.id, on: server)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    init(player: Player) {
        self.player = player
        refreshPlaylist()
        player.servers.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self, self.scope == .servers, self.servers.account(self.server) == nil else { return }
                self.server = ""
                self.enterServer()
            }
        }.store(in: &watching)
        // The index changes as the folders are read; My Files follows it.
        player.musicFolders.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor in self?.refreshFiles() }
        }.store(in: &watching)
    }

    var artists: [String] { musicFolders.index.artists }
    var albums: [String] { musicFolders.index.albums(by: artist.isEmpty ? nil : artist) }

    func scopeChanged() {
        results = []
        status = ""
        switch scope {
        case .files: refreshFiles()
        case .servers: enterServer()
        case .library: search()
        case .catalog: if !query.isEmpty { search() }
        }
    }

    /// My Files filters as you type; the other scopes search on Return.
    func queryChanged() { if scope == .files { refreshFiles() } }

    func refreshFiles() {
        guard scope == .files else { return }
        let index = musicFolders.index
        if !artist.isEmpty, !index.artists.contains(artist) { artist = "" }
        results = index.tracks(artist: artist.isEmpty ? nil : artist, album: album.isEmpty ? nil : album, filter: query)
        let folders = musicFolders.folders.count
        status = musicFolders.isScanning ? "Reading your Music Folders…"
            : folders == 0 ? "" : "\(Self.songs(results.count)) in \(folders) Music Folder\(folders == 1 ? "" : "s")"
    }

    func chooseMusicFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "BitMachine reads the music in these folders, and keeps up as they change."
        guard panel.runModal() == .OK else { return }
        musicFolders.add(panel.urls)
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
                case .files:
                    refreshFiles()
                    return
                case .servers:
                    searchServer(term)
                    return
                case .library:
                    let all = try await player.appleMusic.librarySongs(limit: 500)
                    results = term.isEmpty ? all : all.filter {
                        $0.title.localizedCaseInsensitiveContains(term) || $0.artist.localizedCaseInsensitiveContains(term)
                            || $0.album.localizedCaseInsensitiveContains(term)
                    }
                }
                status = results.isEmpty ? "Nothing found" : Self.songs(results.count)
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

    private var text: Color { Color(cgColor: model.colors.normal.cgColor) }
    private var currentText: Color { Color(cgColor: model.colors.current.cgColor) }
    private var background: Color { Color(cgColor: model.colors.normalBackground.cgColor) }
    private var selection: Color { Color(cgColor: model.colors.selectedBackground.cgColor) }
    @AppStorage(Fonts.listsInSkinFontKey) private var listsInSkinFont = false
    private var font: Font {
        _ = listsInSkinFont  // redraws when the setting changes
        return Fonts.list(skinFont: model.colors.font, size: 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Picker("", selection: $model.scope) {
                        ForEach(LibraryModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField(placeholder, text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.search() }
                    if model.isSearching || model.scope == .files && model.musicFolders.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }
                if model.scope == .files {
                    if model.musicFolders.folders.isEmpty {
                        noMusicFolders
                    } else {
                        HStack(spacing: 6) {
                            column("All Artists", model.artists.map { ($0, $0) }, selection: $model.artist)
                            column("All Albums", model.albums.map { ($0, $0) }, selection: $model.album)
                        }
                        .frame(height: 150)
                    }
                }
                if model.scope == .servers {
                    if model.servers.accounts.isEmpty {
                        noServers
                    } else {
                        HStack(spacing: 6) {
                            column("Pick an artist", model.serverArtists.map { ($0.id, $0.name) },
                                   selection: $model.serverArtist)
                            column("All Albums", model.serverAlbums.map { album in
                                (album.id, album.year.map { "\(album.name) (\($0))" } ?? album.name)
                            }, selection: $model.serverAlbum)
                        }
                        .frame(height: 150)
                    }
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
                    if model.scope == .files { musicFoldersMenu }
                    if model.scope == .servers, !model.servers.accounts.isEmpty { serversMenus }
                    Button("Add to Playlist") {
                        model.add(selectedResults.sorted().map { model.results[$0] }, play: false)
                    }
                    .disabled(selectedResults.isEmpty)
                }
            }
            .padding(8)
            .frame(minHeight: 200)

        }
        .frame(minWidth: 520, minHeight: 300)
        .onChange(of: model.scope) { _, _ in
            selectedResults = []
            model.scopeChanged()
        }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.results) { _, _ in selectedResults = [] }
    }

    private var placeholder: String {
        switch model.scope {
        case .catalog: "Search Apple Music"
        case .library: "Filter your library"
        case .files: "Filter your files"
        case .servers: "Search the Server"
        }
    }

    private var noMusicFolders: some View {
        VStack(spacing: 8) {
            Text("Give BitMachine the folders your music is in. It reads their tags, and keeps up as they change.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add a Music Folder…") { model.chooseMusicFolders() }
        }
        .padding()
    }

    private var noServers: some View {
        VStack(spacing: 8) {
            Text("Sign in to Navidrome, or any Subsonic-compatible server, to play its music here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            SettingsLink { Text("Add a Server in Settings…") }
        }
        .padding()
    }

    @ViewBuilder private var serversMenus: some View {
        if model.servers.accounts.count > 1 {
            Picker("", selection: $model.server) {
                ForEach(model.servers.accounts) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
        }
        Menu("Server Playlists") {
            if model.serverPlaylists.isEmpty { Text("This Server has no playlists") }
            ForEach(model.serverPlaylists) { playlist in
                Button("\(playlist.name) (\(playlist.songCount))") { model.openServerPlaylist(playlist) }
            }
        }
        .fixedSize()
    }

    private var musicFoldersMenu: some View {
        Menu("Music Folders") {
            Button("Add a Music Folder…") { model.chooseMusicFolders() }
            Button("Read Them Again") { model.musicFolders.rescan() }
            if !model.musicFolders.folders.isEmpty {
                Divider()
                ForEach(model.musicFolders.folders, id: \.self) { folder in
                    Button("Remove “\(folder.lastPathComponent)”") { model.musicFolders.remove(folder) }
                }
            }
        }
        .fixedSize()
    }

    /// A column of names with an "all" row at the top; "" stands for all. One click picks a row; rows are told
    /// apart by id, since two can share a name.
    private func column(_ all: String, _ items: [(id: String, name: String)], selection: Binding<String>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach([(id: "", name: all)] + items, id: \.id) { item in
                    let picked = selection.wrappedValue == item.id
                    Button { selection.wrappedValue = item.id } label: {
                        Text(item.name)
                            .lineLimit(1)
                            .font(font)
                            .foregroundStyle(picked ? currentText : text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(picked ? self.selection : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(background)
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
