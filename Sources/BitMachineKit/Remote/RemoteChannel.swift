import CryptoKit
import Foundation

/// The bytes on a Remote connection: each message is a 4-byte big-endian length and then the message, as JSON,
/// sealed with ChaCha20-Poly1305 once the session key is set.
public struct RemoteChannel: Sendable {
    /// Larger than any Playlist a person keeps; a longer frame means a broken or hostile peer.
    public static let maxFrame = 16 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case frameTooLarge(Int)
        /// A sealed frame that doesn't open: the wrong key, or tampering.
        case unreadable
    }

    /// Set once both sides have proved they hold the key; every frame after it is sealed.
    public var sessionKey: SymmetricKey?
    private var buffer = Data()

    public init() {}

    public func frame(_ message: RemoteMessage) throws -> Data {
        var body = try JSONEncoder().encode(message)
        if let sessionKey { body = try ChaChaPoly.seal(body, using: sessionKey).combined }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Takes bytes as they arrive.
    public mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// The next whole message received, or nil until one has fully arrived. Messages come out one at a time, so a
    /// session key set after one applies to the next. Frames this copy can't read are skipped.
    public mutating func next() throws -> RemoteMessage? {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrame else { throw Failure.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { return nil }
            var body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            if let sessionKey {
                guard let box = try? ChaChaPoly.SealedBox(combined: body),
                      let opened = try? ChaChaPoly.open(box, using: sessionKey) else { throw Failure.unreadable }
                body = opened
            }
            if let message = try? JSONDecoder().decode(RemoteMessage.self, from: body) { return message }
        }
        return nil
    }

    /// Every whole message among `bytes` and what came before them.
    public mutating func receive(_ bytes: Data) throws -> [RemoteMessage] {
        append(bytes)
        var messages: [RemoteMessage] = []
        while let message = try next() { messages.append(message) }
        return messages
    }
}

/// The key arithmetic for pairing and connecting (ADR 0005).
///
/// Pairing: each side sends a Curve25519 public key; the shared secret, salted with the Pairing Code the Host shows,
/// gives the pairing key. Each side proves it with an HMAC, so only someone who read the code can pair, and the
/// key itself never crosses the network. Connecting later: both sides prove the Pairing Key with HMACs over fresh
/// nonces, and derive that session's key from it.
public enum RemotePairing {
    public enum Role: String, Sendable { case host, controller }

    public static func newCode() -> String { String(format: "%04d", Int.random(in: 0 ... 9999)) }

    public static func nonce() -> Data { Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }) }

    /// The key both sides derive from the key agreement and the Pairing Code.
    public static func pairingSecret(_ privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data,
                                     code: String) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                              sharedInfo: Data("BitMachine pairing".utf8), outputByteCount: 32)
    }

    public static func pairingProof(_ secret: SymmetricKey, by role: Role) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("paired \(role.rawValue)".utf8), using: secret))
    }

    /// The Pairing Key both sides keep for connecting later.
    public static func pairingKey(_ secret: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("BitMachine pairing key".utf8), outputByteCount: 32)
    }

    public static func connectProof(_ key: SymmetricKey, by role: Role, controllerNonce: Data, hostNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.rawValue.utf8) + controllerNonce + hostNonce, using: key))
    }

    public static func sessionKey(_ key: SymmetricKey, controllerNonce: Data, hostNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: controllerNonce + hostNonce,
                               info: Data("BitMachine session".utf8), outputByteCount: 32)
    }

    /// Compares proofs without leaking where they differ.
    public static func matches(_ proof: Data, _ expected: Data) -> Bool {
        proof.count == expected.count && zip(proof, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
