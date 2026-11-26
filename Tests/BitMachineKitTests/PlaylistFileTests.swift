import Foundation
import Testing
@testable import BitMachineKit

@Suite struct PlaylistFileTests {
    let base = URL(fileURLWithPath: "/Users/someone/Music/Lists")

    @Test func everySourceComesBack() {
        let tracks = [
            Track(source: .appleMusic(id: "1440857781"), title: "Song", artist: "Band", album: "Record", duration: 201),
            Track(source: .localFile(URL(fileURLWithPath: "/Users/someone/Music/a b.mp3")), title: "A B", duration: 60.4),
            Track(source: .server(server: "home", song: "x1"), title: "From Home", artist: "Them"),
            Track(source: .station(URL(string: "https://radio.example/stream")!), title: "Groove"),
        ]
        let text = PlaylistFile.text(for: tracks)
        #expect(text.hasPrefix("#EXTM3U\n"))
        #expect(text.contains("#EXTINF:201,Band - Song\n"))
        #expect(text.contains("\n/Users/someone/Music/a b.mp3\n"))
        #expect(text.contains("\nhttps://radio.example/stream\n"))
        #expect(PlaylistFile.tracks(in: text, base: base) == tracks)
    }

    @Test func opensAnotherPlayersM3U() {
        let text = """
        #EXTM3U
        #EXTINF:245,Some Artist - Some Title
        ../Albums/01 Some Title.flac
        /Volumes/Music/loose.mp3
        #EXTINF:-1,Late Night Radio
        http://stream.example:8000/live

        """
        let tracks = PlaylistFile.tracks(in: text, base: base)
        #expect(tracks.count == 3)
        #expect(tracks[0] == Track(source: .localFile(URL(fileURLWithPath: "/Users/someone/Music/Albums/01 Some Title.flac")),
                                   title: "Some Title", artist: "Some Artist", duration: 245))
        #expect(tracks[1].title == "loose")
        #expect(tracks[2].source == .station(URL(string: "http://stream.example:8000/live")!))
        #expect(tracks[2].title == "Late Night Radio")
        #expect(tracks[2].duration == nil)
    }

    @Test func skipsBitMachineEntriesItCantRead() {
        let text = "#EXTM3U\n#EXTINF:10,Lost\nbitmachine:apple-music:123\n/x.mp3\n"
        #expect(PlaylistFile.tracks(in: text, base: base).map(\.title) == ["x"])
    }
}
