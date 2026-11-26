import CryptoKit
import Foundation
import os
import Testing
@testable import BitMachineKit

/// Answers from a real Navidrome (0.64), captured with curl; image addresses are replaced.
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Subsonic/\(name).json"))
}

/// A client whose Server is these fixtures, by method name, remembering the requests it saw.
private func client(_ answers: [String: String], seen: OSAllocatedUnfairLock<[URL]> = .init(initialState: []))
    -> SubsonicClient {
    let account = ServerAccount(id: "home", name: "Home", url: URL(string: "https://music.example/nd")!, username: "sam")
    return SubsonicClient(account: account, password: "sesame", transport: { request in
        let url = request.url!
        seen.withLock { $0.append(url) }
        let method = url.lastPathComponent
        guard let name = answers[method] else { throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url]) }
        return (try fixture(name), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, salt: { "pepper" })
}

@Suite struct ServerTests {
    @Test func requestsAreSignedWithASaltedTokenNotThePassword() throws {
        let url = client([:]).url("getAlbum", [("id", "a 1")])
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            .map { ($0.name, $0.value ?? "") })
        let token = Insecure.MD5.hash(data: Data("sesamepepper".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(url.path == "/nd/rest/getAlbum")
        #expect(items["t"] == token)
        #expect(items["s"] == "pepper")
        #expect(items["u"] == "sam")
        #expect(items["f"] == "json")
        #expect(items["id"] == "a 1")
        #expect(!url.absoluteString.contains("sesame"))
    }

    @Test func aWrongPasswordIsTheServersError() async throws {
        await #expect(throws: ServerError.server(code: 40, message: "Wrong username or password")) {
            try await client(["ping": "badlogin"]).ping()
        }
        try await client(["ping": "ping"]).ping()
    }

    @Test func browsesArtistsAlbumsAndSongs() async throws {
        let server = client(["getArtists": "getArtists", "getArtist": "getArtist", "getAlbum": "getAlbum"])
        let artists = try await server.artists()
        #expect(artists.map(\.name).starts(with: ["Alpha", "Beta"]))
        let albums = try await server.albums(ofArtist: artists[0].id)
        #expect(Set(albums.map(\.name)) == ["First", "Second"])
        let songs = try await server.songs(ofAlbum: albums[0].id)
        #expect(Set(songs.map(\.title)) == ["Opening", "Closing"])
        #expect(songs.allSatisfy { $0.artist == "Alpha" && $0.album == "First" && $0.duration == 3 })
        guard case let .server(server: id, song: song) = songs[0].source else { Issue.record("not a Server Track"); return }
        #expect(id == "home")
        #expect(!song.isEmpty)
    }

    @Test func searchesAndFindsNothingGracefully() async throws {
        let found = try await client(["search3": "search_sketch"]).search("sketch")
        #expect(found.map(\.title).contains("Sketch"))
        #expect(try await client(["search3": "search_none"]).search("zzzz").isEmpty)
        #expect(try await client(["getPlaylists": "getPlaylists"]).playlists().isEmpty)
    }

    @Test func readsAServerPlaylistAndSavesBackInTheBody() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [URL]())
        let server = client(["getPlaylist": "getPlaylist", "createPlaylist": "ping"], seen: seen)
        let (name, tracks) = try await server.playlist("p")
        #expect(name == "Road Trip")
        #expect(tracks.map(\.title) == ["Fresh", "Second Sketch", "Sketch"])
        try await server.replacePlaylist("p", songs: Array(repeating: "song", count: 2000))
        let saved = try #require(seen.withLock { $0.last })
        #expect(saved.query == nil)  // 2,000 songs go in the body, not the address
    }

    @Test func anUnreachableServerSaysWhereNotTheSignedAddress() async throws {
        do {
            try await client([:]).ping()
            Issue.record("should have thrown")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("music.example"))
            #expect(!text.contains("t="))
            #expect(!text.contains("rest/"))
        }
    }

    @Test func streamsRawUnlessCoreAudioCantPlayIt() {
        let server = client([:])
        #expect(server.streamURL(song: "x", transcode: false).query!.contains("format=raw"))
        #expect(server.streamURL(song: "x", transcode: true).query!.contains("format=mp3"))
    }

    @Test func theCacheKeepsTheRecentlyUsedWithinItsLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmachine-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerCache(directory: directory, limit: 25)
        func download(_ bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 1, count: bytes).write(to: url)
            return url
        }
        let old = try cache.store(download(10), server: "home", song: "old", suffix: "mp3")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: old.path)
        try cache.store(download(10), server: "home", song: "mid", suffix: "m4a")
        #expect(cache.file(server: "home", song: "old") != nil)  // using it makes it recent again
        try cache.store(download(10), server: "home", song: "new", suffix: "flac")
        #expect(cache.file(server: "home", song: "old") != nil)
        #expect(cache.file(server: "home", song: "mid") == nil)
        #expect(cache.file(server: "home", song: "new")?.pathExtension == "flac")
        #expect(cache.file(server: "other", song: "new") == nil)
    }
}

@Suite struct ServerPlaylistTests {
    private func song(_ id: String, on server: String = "home") -> Track {
        Track(source: .server(server: server, song: id), title: id)
    }

    @Test func openingCopiesAndSavingSendsThatServersSongsInOrder() {
        var playlist = Playlist()
        _ = playlist.append([Track(source: .appleMusic(id: "am"), title: "Elsewhere")])
        let reference = ServerPlaylistReference(server: "home", id: "p", name: "Road Trip")
        playlist.open([song("a"), song("b")], from: reference)
        #expect(playlist.entries.map(\.track.title) == ["a", "b"])
        #expect(playlist.serverPlaylist == reference)
        _ = playlist.append([Track(source: .localFile(URL(fileURLWithPath: "/x.mp3")), title: "file"), song("c"),
                             song("z", on: "other")])
        playlist.move([playlist.entries[0].id], to: 4)
        #expect(playlist.songs(on: "home") == ["b", "c", "a"])
        playlist.removeAll()
        #expect(playlist.serverPlaylist == nil)
    }

    @Test func aPlaylistSavedBeforeServerPlaylistsStillLoads() throws {
        var playlist = Playlist(seed: 7)
        _ = playlist.append([song("a")])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(playlist)) as! [String: Any]
        json.removeValue(forKey: "serverPlaylist")
        let loaded = try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.entries.map(\.track.title) == ["a"])
        #expect(loaded.serverPlaylist == nil)
    }
}
