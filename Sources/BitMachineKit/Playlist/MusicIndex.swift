import Foundation

/// What BitMachine knows about the audio files in the Music Folders: each file's Track, read from its tags, and
/// enough about the file to tell when it changes. Browsed by artist and album in the Library Window.
public struct MusicIndex: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var track: Track
        public var modified: Date
        public var size: Int
    }

    public private(set) var folders: [URL] = []
    /// By path, in the order the folders list them.
    public private(set) var files: [File] = []

    public init() {}

    /// Shown for files whose tags name no artist or album.
    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"

    public var tracks: [Track] { files.map(\.track) }

    // MARK: Scanning

    /// The index for `folders` now: files that haven't changed since `previous` keep what was read from them, new and
    /// changed ones are read with `read`, and files that have gone are left out.
    public static func scan(_ folders: [URL], previous: MusicIndex = MusicIndex(),
                            read: @Sendable ([URL]) async -> [Track] = LocalFiles.tracks(for:)) async -> MusicIndex {
        let known = Dictionary(previous.files.map { ($0.track.source, $0) }, uniquingKeysWith: { a, _ in a })
        var index = MusicIndex()
        index.folders = folders
        var found: [(url: URL, modified: Date, size: Int)] = []
        for url in LocalFiles.audioFiles(in: folders) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            found.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
        }
        let unchanged: [URL: File] = Dictionary(uniqueKeysWithValues: found.compactMap { file in
            guard let old = known[.localFile(file.url)], old.modified == file.modified, old.size == file.size else { return nil }
            return (file.url, old)
        })
        let toRead = found.map(\.url).filter { unchanged[$0] == nil }
        let read = Dictionary(zip(toRead, await read(toRead)), uniquingKeysWith: { a, _ in a })
        index.files = found.compactMap { file in
            if let old = unchanged[file.url] { return old }
            guard let track = read[file.url] else { return nil }
            return File(track: track, modified: file.modified, size: file.size)
        }
        return index
    }

    // MARK: Browsing

    private static func artist(_ track: Track) -> String { track.artist.isEmpty ? unknownArtist : track.artist }
    private static func album(_ track: Track) -> String { track.album.isEmpty ? unknownAlbum : track.album }

    private static func sorted(_ names: Set<String>) -> [String] {
        names.sorted { a, b in
            // The unknowns go last.
            let ua = a == unknownArtist || a == unknownAlbum, ub = b == unknownArtist || b == unknownAlbum
            if ua != ub { return ub }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Every artist, A to Z, with Unknown Artist last.
    public var artists: [String] { Self.sorted(Set(tracks.map(Self.artist))) }

    /// The albums by `artist`, or by everyone when nil, A to Z.
    public func albums(by artist: String?) -> [String] {
        Self.sorted(Set(tracks.filter { artist == nil || Self.artist($0) == artist }.map(Self.album)))
    }

    /// The Tracks by `artist` on `album` (nil means any), in folder order (an album's files are usually numbered),
    /// matching `filter` in title, artist or album when it isn't empty.
    public func tracks(artist: String?, album: String?, filter: String = "") -> [Track] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        return tracks.filter { track in
            (artist == nil || Self.artist(track) == artist) && (album == nil || Self.album(track) == album)
                && (term.isEmpty || track.title.localizedCaseInsensitiveContains(term)
                    || track.artist.localizedCaseInsensitiveContains(term)
                    || track.album.localizedCaseInsensitiveContains(term))
        }
    }
}
