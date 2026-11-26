import BitMachineKit
import CoreServices
import Foundation

/// The Music Folders the user has given BitMachine, and the index of what's in them: saved between launches, read
/// again at launch (only new and changed files are read), and kept up to date while BitMachine runs by watching
/// the folders.
@MainActor
final class MusicFolders: ObservableObject {
    @Published private(set) var folders: [URL]
    @Published private(set) var index: MusicIndex
    @Published private(set) var isScanning = false

    private static let foldersKey = "musicFolders"
    private var stream: FSEventStreamRef?
    private var scanTask: Task<Void, Never>?

    static var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMachine/MusicIndex.json")
    }

    init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []).map { URL(fileURLWithPath: $0) }
        index = (try? Data(contentsOf: Self.indexURL)).flatMap { try? JSONDecoder().decode(MusicIndex.self, from: $0) }
            ?? MusicIndex()
        guard !folders.isEmpty else { return }
        watch()
        rescan()
    }

    /// Adds folders, leaving out ones already covered by a Music Folder; folders inside a new one are folded into it.
    func add(_ urls: [URL]) {
        var next = folders
        for url in urls.map(\.standardizedFileURL) where !next.contains(where: { Self.isInside(url, $0) }) {
            next.removeAll { Self.isInside($0, url) }
            next.append(url)
        }
        guard next != folders else { return }
        setFolders(next)
    }

    func remove(_ folder: URL) { setFolders(folders.filter { $0 != folder }) }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.path, base = folder.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func setFolders(_ next: [URL]) {
        folders = next
        UserDefaults.standard.set(next.map(\.path), forKey: Self.foldersKey)
        watch()
        rescan()
    }

    // MARK: Reading

    /// Reads the folders again, soon: a burst of changes is read once.
    func rescan(after delay: Duration = .zero) {
        scanTask?.cancel()
        let folders = folders
        scanTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            isScanning = true
            let next = await MusicIndex.scan(folders, previous: index)
            guard !Task.isCancelled else { return }
            isScanning = false
            guard next != index else { return }
            index = next
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.indexURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: Self.indexURL, options: .atomic)
        } catch {
            NSLog("BitMachine: couldn't save the Music Folders' index: \(error)")
        }
    }

    // MARK: Watching

    private func watch() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let changed: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let folders = Unmanaged<MusicFolders>.fromOpaque(info).takeUnretainedValue()
            // The stream runs on the main queue.
            MainActor.assumeIsolated { folders.rescan(after: .seconds(1)) }
        }
        guard let stream = FSEventStreamCreate(nil, changed, &context, folders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
