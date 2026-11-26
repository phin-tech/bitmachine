import Foundation

/// Server Tracks' audio kept on disk: the ones played lately and the ones read ahead, so they start at once and play
/// when the Server can't be reached. The least recently played go first when it grows past its limit.
public struct ServerCache: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 2_000_000_000) {
        self.directory = directory
        self.limit = limit
    }

    private func folder(_ server: String) -> URL { directory.appendingPathComponent(Self.safe(server), isDirectory: true) }

    private static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// The song's file, if it's here; finding it counts as using it.
    public func file(server: String, song: String) -> URL? {
        let prefix = Self.safe(song) + "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder(server).path),
              let name = names.first(where: { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }) else { return nil }
        let url = folder(server).appendingPathComponent(name)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Moves a whole downloaded file in, named by its kind (`suffix`, such as "mp3"), and makes room.
    @discardableResult
    public func store(_ downloaded: URL, server: String, song: String, suffix: String) throws -> URL {
        let folder = folder(server)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.safe(song) + "." + (suffix.isEmpty ? "audio" : Self.safe(suffix)))
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: downloaded, to: url)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        trim(keeping: url)
        return url
    }

    /// Removes the least recently used files until the cache fits its limit, never `keeping`.
    public func trim(keeping: URL? = nil) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, used: Date, size: Int)] = []
        while let url = items.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.used < $1.used }) where total > limit {
            guard file.url.standardizedFileURL != keeping?.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
