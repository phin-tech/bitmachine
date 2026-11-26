import Foundation
import Testing
@testable import BitMachineKit

private func tracks(_ titles: String...) -> [Track] {
    titles.map { Track(source: .appleMusic(id: $0), title: $0) }
}

@Suite struct PlaylistTests {
    @Test func appendingMakesTheFirstTrackCurrent() {
        var playlist = Playlist(seed: 1)
        playlist.append(tracks("a", "b"))
        #expect(playlist.currentEntry?.track.title == "a")
        playlist.append(tracks("c"))
        #expect(playlist.currentEntry?.track.title == "a")
    }

    @Test func theSameTrackCanBeThereTwice() {
        var playlist = Playlist(seed: 1)
        playlist.append(tracks("a", "a"))
        #expect(playlist.entries.count == 2)
        #expect(playlist.entries[0].id != playlist.entries[1].id)
    }

    @Test func nextStopsAtTheEndUnlessRepeating() {
        var playlist = Playlist(seed: 1)
        playlist.append(tracks("a", "b"))
        let advanced0 = playlist.advance(); #expect(advanced0)
        #expect(playlist.currentEntry?.track.title == "b")
        let stopped = !playlist.advance(); #expect(stopped)
        playlist.repeats = true
        let advanced1 = playlist.advance(); #expect(advanced1)
        #expect(playlist.currentEntry?.track.title == "a")
        #expect(playlist.previous()?.track.title == "b")
    }

    @Test func unavailableTracksAreSkippedButKeepTheirPlace() {
        var playlist = Playlist(seed: 1)
        let entries = playlist.append(tracks("a", "b", "c"))
        playlist.markUnavailable(entries[1].id, reason: "not in your region")
        #expect(playlist.next()?.track.title == "c")
        #expect(playlist.entries.map(\.track.title) == ["a", "b", "c"])
        playlist.markUnavailable(entries[1].id, reason: nil)
        #expect(playlist.next()?.track.title == "b")
    }

    @Test func nothingPlayableMeansNoNext() {
        var playlist = Playlist(seed: 1)
        let entries = playlist.append(tracks("a", "b"))
        playlist.repeats = true
        playlist.markUnavailable(entries[0].id, reason: "x")
        playlist.markUnavailable(entries[1].id, reason: "x")
        #expect(playlist.next() == nil)
    }

    @Test func shuffleVisitsEveryEntryOnceStartingFromTheCurrent() {
        var playlist = Playlist(seed: 42)
        playlist.append(tracks("a", "b", "c", "d", "e"))
        playlist.select(playlist.entries[2].id)
        playlist.shuffle = true
        #expect(playlist.playOrder.first == playlist.entries[2].id)
        var seen = [playlist.currentEntry!.track.title]
        while playlist.advance() { seen.append(playlist.currentEntry!.track.title) }
        #expect(seen.sorted() == ["a", "b", "c", "d", "e"])
    }

    @Test func removingTheCurrentEntryMovesToTheNext() {
        var playlist = Playlist(seed: 1)
        let entries = playlist.append(tracks("a", "b", "c"))
        playlist.select(entries[1].id)
        playlist.remove([entries[1].id])
        #expect(playlist.currentEntry?.track.title == "c")
        playlist.remove([entries[2].id])
        #expect(playlist.currentEntry?.track.title == "a")
        playlist.remove([entries[0].id])
        #expect(playlist.currentEntry == nil)
    }

    @Test func moving() {
        var playlist = Playlist(seed: 1)
        let e = playlist.append(tracks("a", "b", "c", "d"))
        playlist.move([e[0].id, e[1].id], to: 4)
        #expect(playlist.entries.map(\.track.title) == ["c", "d", "a", "b"])
        playlist.move([e[3].id], to: 0)
        #expect(playlist.entries.map(\.track.title) == ["d", "c", "a", "b"])
    }

    @Test func displayTitle() {
        #expect(Track(source: .appleMusic(id: "1"), title: "One More Time", artist: "Daft Punk").displayTitle
            == "Daft Punk - One More Time")
        #expect(Track(source: .appleMusic(id: "1"), title: "Untitled").displayTitle == "Untitled")
    }
}
