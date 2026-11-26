import BitMachineKit
import Foundation
import Security

/// The Servers the user has signed in to (passwords in the login Keychain), and fetching their songs' audio into the
/// cache: one download per song however many ask for it, read-ahead included.
@MainActor
final class Servers: ObservableObject {
    @Published private(set) var accounts: [ServerAccount]

    private static let accountsKey = "servers"
    let cache = ServerCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tech.phin.bitmachine/Servers", isDirectory: true))
    private var downloads: [String: Task<URL, Error>] = [:]

    init() {
        accounts = UserDefaults.standard.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([ServerAccount].self, from: $0) } ?? []
    }

    func account(_ id: String) -> ServerAccount? { accounts.first { $0.id == id } }

    /// Checks the address and sign-in, then saves the Server.
    func add(_ account: ServerAccount, password: String) async throws {
        try await SubsonicClient(account: account, password: password).ping()
        try Keychain.set(password, for: account.id)
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        save()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        Keychain.remove(id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    func client(for id: String) throws -> SubsonicClient {
        guard let account = account(id) else { throw ServersError.gone }
        guard let password = Keychain.password(for: id) else { throw ServersError.noPassword(account.name) }
        return SubsonicClient(account: account, password: password)
    }

    // MARK: Audio

    /// The song's audio as a file: from the cache if it's there (so it plays with the Server out of reach), else
    /// downloaded whole into it.
    func file(server: String, song: String) async throws -> URL {
        if let cached = cache.file(server: server, song: song) { return cached }
        let key = server + "/" + song
        if let running = downloads[key] { return try await running.value }
        let client = try client(for: server)
        let cache = cache
        let task = Task.detached { () async throws -> URL in
            let info = try await client.song(song)
            let playable = LocalFiles.extensions.contains(info.suffix.lowercased())
            let request = client.request(client.streamURL(song: song, transcode: !playable), timeout: 30)
            let (temporary, response): (URL, URLResponse)
            do {
                (temporary, response) = try await URLSession.shared.download(for: request)
            } catch let error as URLError {
                throw ServerError.unreachable(host: client.account.url.host ?? "the Server",
                                              reason: error.code == .timedOut ? "it took too long" : "network error \(error.code.rawValue)")
            }
            // An error comes back as JSON or XML; only audio goes in the cache.
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, type.hasPrefix("audio/") || type == "application/octet-stream" else {
                try? FileManager.default.removeItem(at: temporary)
                throw ServerError.notAudio(type.isEmpty ? "HTTP \(status)" : type)
            }
            return try cache.store(temporary, server: server, song: song, suffix: playable ? info.suffix : "mp3")
        }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }

    /// Fetches a song ahead of time, quietly, so it starts at once when its turn comes.
    func readAhead(server: String, song: String) {
        guard cache.file(server: server, song: song) == nil, downloads[server + "/" + song] == nil else { return }
        Task { _ = try? await file(server: server, song: song) }
    }
}

enum ServersError: LocalizedError {
    case gone
    case noPassword(String)

    var errorDescription: String? {
        switch self {
        case .gone: "That Server has been removed"
        case let .noPassword(name): "BitMachine has no password for \(name); add the Server again in Settings"
        }
    }
}

/// Server passwords in the login Keychain.
enum Keychain {
    private static let service = "BitMachine Server"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ password: String, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "BitMachine Server"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't save the password in the Keychain (\(status))"])
        }
    }

    static func password(for account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
