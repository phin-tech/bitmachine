import CryptoKit
import Foundation
import Testing
@testable import BitMachineKit

@Suite struct RemoteChannelTests {
    @Test func messagesSurviveBeingSplitAnywhere() throws {
        let sender = RemoteChannel()
        let messages: [RemoteMessage] = [
            .command(.press(.play)),
            .command(.edit(.move([UUID()], to: 3))),
            .notice("hello"),
        ]
        let bytes = try messages.map(sender.frame).reduce(Data(), +)
        for split in [1, 3, 4, 5, 17, bytes.count - 1] {
            var receiver = RemoteChannel()
            let received = try receiver.receive(bytes.prefix(split)) + receiver.receive(bytes.dropFirst(split))
            #expect(received == messages)
        }
    }

    @Test func sealedFramesOpenOnlyWithTheKey() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = RemoteChannel()
        sender.sessionKey = key
        let frame = try sender.frame(.notice("secret title"))
        #expect(!String(decoding: frame, as: UTF8.self).contains("secret"))

        var receiver = RemoteChannel()
        receiver.sessionKey = key
        #expect(try receiver.receive(frame) == [.notice("secret title")])

        var stranger = RemoteChannel()
        stranger.sessionKey = SymmetricKey(size: .bits256)
        #expect(throws: RemoteChannel.Failure.unreadable) { try stranger.receive(frame) }
    }

    @Test func aKeySetBetweenMessagesOpensTheNext() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = RemoteChannel()
        let plain = try sender.frame(.proof(Data([1])))
        sender.sessionKey = key
        let sealed = try sender.frame(.notice("after"))

        var receiver = RemoteChannel()
        receiver.append(plain + sealed)
        #expect(try receiver.next() == .proof(Data([1])))
        receiver.sessionKey = key
        #expect(try receiver.next() == .notice("after"))
        #expect(try receiver.next() == nil)
    }

    @Test func refusesAHugeFrameBeforeReadingIt() {
        var receiver = RemoteChannel()
        #expect(throws: RemoteChannel.Failure.self) { try receiver.receive(Data([0xFF, 0xFF, 0xFF, 0xFF, 0])) }
    }

    @Test func skipsMessagesFromANewerVersion() throws {
        let unknown = Data(#"{"somethingNew":{"x":1}}"#.utf8)
        var length = UInt32(unknown.count).bigEndian
        var receiver = RemoteChannel()
        let after = try RemoteChannel().frame(.notice("still here"))
        #expect(try receiver.receive(Data(bytes: &length, count: 4) + unknown + after) == [.notice("still here")])
    }
}

@Suite struct RemotePairingTests {
    @Test func bothSidesAgreeOnlyWithTheSameCode() throws {
        let host = Curve25519.KeyAgreement.PrivateKey(), controller = Curve25519.KeyAgreement.PrivateKey()
        let hostSecret = try RemotePairing.pairingSecret(host, peer: controller.publicKey.rawRepresentation, code: "0427")
        let typed = try RemotePairing.pairingSecret(controller, peer: host.publicKey.rawRepresentation, code: "0427")
        let mistyped = try RemotePairing.pairingSecret(controller, peer: host.publicKey.rawRepresentation, code: "0428")

        let expected = RemotePairing.pairingProof(hostSecret, by: .controller)
        #expect(RemotePairing.matches(RemotePairing.pairingProof(typed, by: .controller), expected))
        #expect(!RemotePairing.matches(RemotePairing.pairingProof(mistyped, by: .controller), expected))
        // A proof from one side can't be replayed as the other's.
        #expect(!RemotePairing.matches(RemotePairing.pairingProof(typed, by: .host), expected))
        #expect(RemotePairing.pairingKey(hostSecret) == RemotePairing.pairingKey(typed))
    }

    @Test func connectingProvesTheKeyAndGivesBothTheSessionKey() {
        let key = SymmetricKey(size: .bits256)
        let c = RemotePairing.nonce(), h = RemotePairing.nonce()
        let proof = RemotePairing.connectProof(key, by: .controller, controllerNonce: c, hostNonce: h)
        #expect(RemotePairing.matches(proof, RemotePairing.connectProof(key, by: .controller, controllerNonce: c, hostNonce: h)))
        #expect(!RemotePairing.matches(proof, RemotePairing.connectProof(SymmetricKey(size: .bits256), by: .controller,
                                                                         controllerNonce: c, hostNonce: h)))
        #expect(!RemotePairing.matches(proof, RemotePairing.connectProof(key, by: .controller, controllerNonce: c,
                                                                         hostNonce: RemotePairing.nonce())))
        #expect(RemotePairing.sessionKey(key, controllerNonce: c, hostNonce: h)
            == RemotePairing.sessionKey(key, controllerNonce: c, hostNonce: h))
        #expect(RemotePairing.newCode().count == 4)
    }
}

@Suite struct RemoteStatusTests {
    @Test func copiesTheMusicButNotTheWindow() {
        var host = MainWindowState()
        host.playback = .playing
        host.title = "Band - Song"
        host.elapsed = 42
        host.volume = 0.3
        host.shuffle = true
        var bars = VisualizerBars()
        bars.update([0.5, 0.9], dt: 0.03)
        host.visualizer = bars

        var controller = MainWindowState()
        controller.isWindowshade = true
        controller.showsRemaining = true
        RemoteStatus(host).apply(to: &controller)
        #expect(controller.playback == .playing)
        #expect(controller.title == "Band - Song")
        #expect(controller.elapsed == 42)
        #expect(controller.volume == 0.3)
        #expect(controller.shuffle)
        #expect(controller.visualizer?.bars == bars.bars && controller.visualizer?.peaks == bars.peaks)
        #expect(controller.isWindowshade && controller.showsRemaining)
    }

    @Test func editsApplyByEntry() {
        var playlist = Playlist(seed: 1)
        let entries = playlist.append([Track(source: .station(URL(string: "https://a.example")!), title: "b"),
                                       Track(source: .station(URL(string: "https://b.example")!), title: "a")])
        PlaylistEdit.sort(.title).apply(to: &playlist)
        #expect(playlist.entries.map(\.track.title) == ["a", "b"])
        PlaylistEdit.remove([entries[0].id]).apply(to: &playlist)
        #expect(playlist.entries.map(\.track.title) == ["a"])
    }
}
