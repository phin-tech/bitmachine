import Foundation
import os
import Testing
@testable import BitMachineKit

/// Reads "Artist - Album - Title.wav" names as tags, and remembers which files it was asked to read.
private final class FakeReader: Sendable {
    let asked = OSAllocatedUnfairLock(initialState: [String]())

    func read(_ urls: [URL]) async -> [Track] {
        asked.withLock { $0 += urls.map(\.lastPathComponent) }
        return urls.map { url in
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
            return Track(source: .localFile(url), title: parts.last ?? "", artist: parts.count > 2 ? parts[0] : "",
                         album: parts.count > 2 ? parts[1] : "")
        }
    }
}

@Suite struct MusicIndexTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bitmachine-index-\(UUID().uuidString)")

    private func touch(_ name: String, _ contents: String = "x") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func aRescanReadsOnlyNewAndChangedFilesAndForgetsGoneOnes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch("A - X - 1 One.mp3")
        try touch("A - X - 2 Two.mp3")
        try touch("B - Y - Gone.mp3")
        let first = FakeReader()
        let index = await MusicIndex.scan([folder], read: first.read)
        #expect(index.files.count == 3)
        #expect(first.asked.withLock { $0.count } == 3)

        try touch("A - X - 2 Two.mp3", "longer now")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("B - Y - Gone.mp3"))
        try touch("C - Z - New.mp3")
        let second = FakeReader()
        let again = await MusicIndex.scan([folder], previous: index, read: second.read)
        #expect(second.asked.withLock { $0.sorted() } == ["A - X - 2 Two.mp3", "C - Z - New.mp3"])
        #expect(again.tracks.map(\.title) == ["1 One", "2 Two", "New"])
        #expect(again.folders == [folder])
    }

    @Test func browsesByArtistThenAlbum() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["beta - Second - 1 b.mp3", "Alpha - First - 2 a.mp3", "Alpha - First - 1 a.mp3",
                     "Alpha - Other - 1 c.mp3", "untagged.mp3"] {
            try touch(name)
        }
        let index = await MusicIndex.scan([folder], read: FakeReader().read)
        #expect(index.artists == ["Alpha", "beta", MusicIndex.unknownArtist])
        #expect(index.albums(by: "Alpha") == ["First", "Other"])
        #expect(index.albums(by: nil) == ["First", "Other", "Second", MusicIndex.unknownAlbum])
        #expect(index.tracks(artist: "Alpha", album: "First").map(\.title) == ["1 a", "2 a"])
        #expect(index.tracks(artist: MusicIndex.unknownArtist, album: nil).map(\.title) == ["untagged"])
        #expect(index.tracks(artist: nil, album: nil, filter: "second").map(\.title) == ["1 b"])
    }

    @Test func survivesASaveAndLoad() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch("A - X - Song.mp3")
        let index = await MusicIndex.scan([folder], read: FakeReader().read)
        let loaded = try JSONDecoder().decode(MusicIndex.self, from: JSONEncoder().encode(index))
        #expect(loaded == index)
    }
}
