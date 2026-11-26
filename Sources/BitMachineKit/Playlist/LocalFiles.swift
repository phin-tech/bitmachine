import AVFoundation
import Foundation

/// Turning files and folders on disk into Local File Tracks.
public enum LocalFiles {
    /// The kinds of audio file BitMachine plays (what Core Audio decodes).
    public static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "wave", "aif",
                                                 "aiff", "aifc", "caf", "mp4"]

    public static func isAudio(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// The audio files among `urls`, with folders opened up (all the way down), in Finder's order within each folder.
    public static func audioFiles(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var inFolder: [URL] = []
                while let item = items?.nextObject() as? URL {
                    if isAudio(item) { inFolder.append(item) }
                }
                found += inFolder.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isAudio(url) {
                found.append(url)
            }
        }
        return found
    }

    /// A Track for a file, from its tags where it has them, else its name.
    public static func track(for url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title: String?, artist: String?, album: String?
        var duration: TimeInterval?
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                default: break
                }
            }
        }
        if let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 { duration = time.seconds }
        return Track(source: .localFile(url), title: title ?? url.deletingPathExtension().lastPathComponent,
                     artist: artist ?? "", album: album ?? "", duration: duration)
    }

    /// Tracks for many files, read a few at a time, in the order given.
    public static func tracks(for urls: [URL]) async -> [Track] {
        await withTaskGroup(of: (Int, Track).self) { group in
            var results = [Track?](repeating: nil, count: urls.count)
            var next = 0
            for _ in 0 ..< min(8, urls.count) {
                let i = next
                group.addTask { (i, await LocalFiles.track(for: urls[i])) }
                next += 1
            }
            for await (i, read) in group {
                results[i] = read
                if next < urls.count {
                    let j = next
                    group.addTask { (j, await LocalFiles.track(for: urls[j])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
