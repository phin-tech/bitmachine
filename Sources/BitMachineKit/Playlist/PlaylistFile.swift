import Foundation

/// Playlist Files: extended M3U8, so other players can still read the Local Files and Stations in one. Each entry
/// also carries a `#BITMACHINE:` line with its whole Track, so Apple Music and Server Tracks come back too; those
/// have `bitmachine:` locations other players skip. Plain M3U files from other players open as well.
public enum PlaylistFile {
    public static let extensions: Set<String> = ["m3u8", "m3u"]
    private static let marker = "#BITMACHINE:"

    public static func text(for tracks: [Track]) -> String {
        var lines = ["#EXTM3U"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for track in tracks {
            lines.append("#EXTINF:\(track.duration.map { Int($0.rounded()) } ?? -1),\(track.displayTitle)")
            if let json = try? encoder.encode(track), let line = String(data: json, encoding: .utf8) {
                lines.append(marker + line)
            }
            lines.append(location(of: track))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func location(of track: Track) -> String {
        switch track.source {
        case let .localFile(url): url.path
        case let .station(url): url.absoluteString
        case let .appleMusic(id): "bitmachine:apple-music:\(id)"
        case let .server(server, song): "bitmachine:server:\(server):\(song)"
        }
    }

    /// The Tracks in a Playlist File; relative paths are read against `base`, the file's folder.
    public static func tracks(in text: String, base: URL) -> [Track] {
        var tracks: [Track] = []
        var saved: Track?
        var info: (duration: TimeInterval?, title: String)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "#EXTM3U" { continue }
            if line.hasPrefix(marker) {
                saved = try? JSONDecoder().decode(Track.self, from: Data(line.dropFirst(marker.count).utf8))
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let comma = body.firstIndex(of: ",") ?? body.endIndex
                let seconds = Double(body[..<comma].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
                let title = comma < body.endIndex ? String(body[body.index(after: comma)...]) : ""
                info = (seconds, title)
            } else if line.hasPrefix("#") {
                continue
            } else {
                if let saved { tracks.append(saved) } else if let track = track(at: line, info: info, base: base) {
                    tracks.append(track)
                }
                saved = nil
                info = nil
            }
        }
        return tracks
    }

    /// A Track for a plain M3U entry: a web address is a Station, anything else a file.
    private static func track(at location: String, info: (duration: TimeInterval?, title: String)?, base: URL) -> Track? {
        if location.hasPrefix("bitmachine:") { return nil }
        if let url = URL(string: location), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let name = info?.title.isEmpty == false ? info!.title : (url.host() ?? location)
            return Track(source: .station(url), title: name)
        }
        let url = location.hasPrefix("/") ? URL(fileURLWithPath: location)
            : location.hasPrefix("file://") ? (URL(string: location) ?? base)
            : base.appendingPathComponent(location)
        // "Artist - Title", as players write it; else the file's name.
        let parts = (info?.title ?? "").components(separatedBy: " - ")
        let title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ")
            : (info?.title.isEmpty == false ? info!.title : url.deletingPathExtension().lastPathComponent)
        return Track(source: .localFile(url.standardizedFileURL), title: title, artist: parts.count > 1 ? parts[0] : "",
                     duration: info?.duration)
    }
}
