import AppKit
import BitMachineKit
import CryptoKit
import Foundation
import Network

/// Remote Control (ADR 0005): one BitMachine, the Controller, works another on the same network, the Host. They find
/// each other with Bonjour, pair once with a Pairing Code the Host shows, and talk over an encrypted connection.
enum Remote {
    static let serviceType = "_bitmachine._tcp"
    static let hostingKey = "remoteHosting"

    /// This copy's identity on the network, the same across launches.
    static var id: String {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["BITMACHINE_REMOTE_ID"] { return id }
        #endif
        if let id = UserDefaults.standard.string(forKey: "remoteID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "remoteID")
        return id
    }

    static var name: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["BITMACHINE_REMOTE_NAME"] { return name }
        #endif
        return Host.current().localizedName ?? "Mac"
    }

    /// The Pairing Keys this Mac keeps as a Host, one per Controller paired with it.
    static let controllerKeys = RemoteKeychain(service: "BitMachine Remote Controllers")
    /// The Pairing Keys this Mac keeps as a Controller, one per Host it has paired with.
    static let hostKeys = RemoteKeychain(service: "BitMachine Remote Hosts")
}

struct RemoteKeychain {
    let service: String

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func key(for account: String) -> SymmetricKey? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func set(_ key: SymmetricKey, for account: String, label: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrLabel as String] = "BitMachine Remote: \(label)"
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
    func removeAll() { SecItemDelete(query() as CFDictionary) }
}

/// One Remote connection, either end: frames in and out on the main queue.
@MainActor
final class RemoteConnection {
    private let connection: NWConnection
    private var channel = RemoteChannel()
    private var closed = false
    /// Handles each message as it arrives; may set the session key before the next is read.
    var onMessage: ((RemoteMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String?) -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    convenience init(to endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: .tcp))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onReady?()
                case let .failed(error): self?.close("\(error.localizedDescription)")
                case let .waiting(error): self?.close("\(error.localizedDescription)")
                case .cancelled: self?.close(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func encrypt(with key: SymmetricKey) { channel.sessionKey = key }

    func send(_ message: RemoteMessage) {
        guard !closed, let data = try? channel.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
        onMessage = nil
        onClose = nil
        onReady = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data {
                    self.channel.append(data)
                    do {
                        while !self.closed, let message = try self.channel.next() { self.onMessage?(message) }
                    } catch {
                        self.close("the other Mac sent something unreadable")
                        return
                    }
                }
                if isComplete || error != nil { self.close(error.map { "\($0.localizedDescription)" }) } else { self.receive() }
            }
        }
    }
}

// MARK: - Host

/// Lets other Macs control this one, when the user allows it in Settings.
@MainActor
final class RemoteHost {
    private let player: Player
    private var listener: NWListener?
    private var sessions: [HostSession] = []
    /// The one pairing under way: a second Controller must wait its turn.
    private weak var pairing: HostSession?
    private var codePanel: NSPanel?
    private var pushTimer: Timer?
    private var lastStatus: RemoteStatus?
    private var playlistChanged = false
    private var equalizerChanged = false

    init(player: Player) {
        self.player = player
        player.observeState { [weak self] in self?.startPushing() }
        player.observePlaylist { [weak self] in self?.playlistChanged = true; self?.startPushing() }
        player.observeEqualizer { [weak self] in self?.equalizerChanged = true; self?.startPushing() }
    }

    static var isAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BITMACHINE_REMOTE_PORT"] != nil { return true }
        #endif
        return UserDefaults.standard.bool(forKey: Remote.hostingKey)
    }

    /// Starts or stops listening to match the setting.
    func update() {
        if Self.isAllowed { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        do {
            var port = NWEndpoint.Port.any
            #if DEBUG
            if let fixed = ProcessInfo.processInfo.environment["BITMACHINE_REMOTE_PORT"].flatMap(UInt16.init) {
                port = NWEndpoint.Port(rawValue: fixed) ?? .any
            }
            #endif
            let listener = try NWListener(using: .tcp, on: port)
            listener.service = NWListener.Service(name: Remote.name, type: Remote.serviceType,
                                                  txtRecord: NWTXTRecord(["id": Remote.id]))
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state { NSLog("BitMachine Remote: hosting stopped: %@", "\(error)") }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("BitMachine Remote: couldn't host: %@", "\(error)")
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        sessions.forEach { $0.connection.close(nil) }
        sessions = []
        closeCodePanel()
    }

    /// Forgets every Controller paired with this Mac; they must pair again.
    func forgetControllers() {
        Remote.controllerKeys.removeAll()
        sessions.forEach { $0.connection.close(nil) }
        sessions = []
    }

    private func accept(_ connection: NWConnection) {
        let session = HostSession(connection: RemoteConnection(connection))
        sessions.append(session)
        session.connection.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        session.connection.onClose = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.sessions.removeAll { $0 === session }
            if self.pairing === session { self.closeCodePanel() }
        }
        session.connection.start()
        // A connection that doesn't finish connecting soon is let go.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak session] _ in
            MainActor.assumeIsolated {
                if let session, !session.isAuthenticated, !session.isPairing { session.connection.close(nil) }
            }
        }
    }

    private func handle(_ message: RemoteMessage, from session: HostSession) {
        switch (session.phase, message) {
        case let (.new, .hello(hello)):
            guard hello.version == RemoteMessage.version else {
                return deny(session, "this BitMachine is a different version; update both Macs")
            }
            guard let key = Remote.controllerKeys.key(for: hello.controllerID) else { return deny(session, "unpaired") }
            let nonce = RemotePairing.nonce()
            session.phase = .challenged(controller: hello, key: key, nonce: nonce)
            session.connection.send(.challenge(hostID: Remote.id, nonce: nonce, proof: RemotePairing.connectProof(
                key, by: .host, controllerNonce: hello.nonce, hostNonce: nonce)))

        case let (.challenged(controller, key, nonce), .proof(proof)):
            let expected = RemotePairing.connectProof(key, by: .controller, controllerNonce: controller.nonce, hostNonce: nonce)
            guard RemotePairing.matches(proof, expected) else { return deny(session, "unpaired") }
            session.connection.encrypt(with: RemotePairing.sessionKey(key, controllerNonce: controller.nonce, hostNonce: nonce))
            session.phase = .authenticated(name: controller.name)
            session.connection.send(.playlist(player.playlist))
            session.connection.send(.equalizer(player.equalizer))
            session.connection.send(.status(RemoteStatus(player.state)))

        case let (.new, .pairRequest(hello, publicKey)):
            guard hello.version == RemoteMessage.version else {
                return deny(session, "this BitMachine is a different version; update both Macs")
            }
            guard pairing == nil else { return deny(session, "\(Remote.name) is pairing with another Mac; try again soon") }
            var code = RemotePairing.newCode()
            #if DEBUG
            if let fixed = ProcessInfo.processInfo.environment["BITMACHINE_PAIRING_CODE"] { code = fixed }
            #endif
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            guard let secret = try? RemotePairing.pairingSecret(privateKey, peer: publicKey, code: code) else {
                return deny(session, "pairing failed")
            }
            session.phase = .pairing(controller: hello, secret: secret)
            pairing = session
            showCodePanel(code, for: hello.name)
            session.connection.send(.pairChallenge(hostID: Remote.id, publicKey: privateKey.publicKey.rawRepresentation))
            // The code is good for two minutes.
            Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session, session.isPairing else { return }
                    self.deny(session, "the Pairing Code expired")
                }
            }

        case let (.pairing(controller, secret), .pairProof(proof)):
            closeCodePanel()
            // One try per code: a wrong one ends the pairing, and the next try shows a new code.
            guard RemotePairing.matches(proof, RemotePairing.pairingProof(secret, by: .controller)) else {
                return deny(session, "that isn't the code \(Remote.name) showed")
            }
            Remote.controllerKeys.set(RemotePairing.pairingKey(secret), for: controller.controllerID, label: controller.name)
            session.phase = .new
            session.connection.send(.paired(RemotePairing.pairingProof(secret, by: .host)))

        case let (.authenticated, .command(command)):
            player.perform(command)

        default:
            // Anything out of turn from a Controller that isn't connected yet ends the connection.
            if !session.isAuthenticated { session.connection.close(nil) }
        }
    }

    private func deny(_ session: HostSession, _ reason: String) {
        if pairing === session { closeCodePanel() }
        session.connection.send(.denied(reason))
        // Let the message go out before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { session.connection.close(nil) }
    }

    // MARK: Sending the Host's music

    /// Sends what changed to every connected Controller, at most 15 times a second.
    private func startPushing() {
        guard pushTimer == nil, sessions.contains(where: \.isAuthenticated) else { return }
        pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
    }

    private func push() {
        pushTimer = nil
        let connected = sessions.filter(\.isAuthenticated)
        if playlistChanged { connected.forEach { $0.connection.send(.playlist(player.playlist)) } }
        if equalizerChanged { connected.forEach { $0.connection.send(.equalizer(player.equalizer)) } }
        let status = RemoteStatus(player.state)
        if status != lastStatus { connected.forEach { $0.connection.send(.status(status)) } }
        lastStatus = status
        playlistChanged = false
        equalizerChanged = false
    }

    // MARK: The Pairing Code

    private func showCodePanel(_ code: String, for name: String) {
        codePanel?.close()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 170), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Pair with \(name)"
        let view = NSStackView()
        view.orientation = .vertical
        view.spacing = 10
        view.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let digits = NSTextField(labelWithString: code.map(String.init).joined(separator: " "))
        digits.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        let label = NSTextField(wrappingLabelWithString: "To let \(name) control BitMachine on this Mac, type this code there.")
        label.alignment = .center
        view.addArrangedSubview(digits)
        view.addArrangedSubview(label)
        panel.contentView = view
        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        codePanel = panel
    }

    private func closeCodePanel() {
        codePanel?.close()
        codePanel = nil
        if let pairing, pairing.isPairing { pairing.phase = .new }
        pairing = nil
    }
}

@MainActor
final class HostSession {
    enum Phase {
        case new
        case challenged(controller: RemoteMessage.Hello, key: SymmetricKey, nonce: Data)
        case pairing(controller: RemoteMessage.Hello, secret: SymmetricKey)
        case authenticated(name: String)
    }

    let connection: RemoteConnection
    var phase = Phase.new

    init(connection: RemoteConnection) { self.connection = connection }

    var isAuthenticated: Bool { if case .authenticated = phase { true } else { false } }
    var isPairing: Bool { if case .pairing = phase { true } else { false } }
}

// MARK: - Controller

/// What Player holds while controlling a Host: commands go out through it.
@MainActor
final class RemoteLink {
    let host: String
    fileprivate let connection: RemoteConnection

    fileprivate init(host: String, connection: RemoteConnection) {
        self.host = host
        self.connection = connection
    }

    func send(_ command: RemoteCommand) { connection.send(.command(command)) }
}

/// Finds Hosts on the network, and connects this Mac to one as its Controller.
@MainActor
final class RemoteController: ObservableObject {
    struct FoundHost: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    @Published private(set) var found: [FoundHost] = []
    /// The Host being connected to or controlled, and how that's going.
    @Published private(set) var host: String?
    @Published private(set) var status = ""
    @Published private(set) var isControlling = false

    private let player: Player
    private var browser: NWBrowser?
    private var connection: RemoteConnection?

    init(player: Player) { self.player = player }

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Remote.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found = Self.hosts(in: results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case let .failed(error) = state { self?.status = "Can't look for other Macs: \(error.localizedDescription)" }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private static func hosts(in results: Set<NWBrowser.Result>) -> [FoundHost] {
        results.compactMap { result -> FoundHost? in
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(record) = result.metadata, let id = record["id"], id != Remote.id else { return nil }
            return FoundHost(id: id, name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Connecting

    func connect(to found: FoundHost) { connect(to: found.endpoint, name: found.name) }

    func connect(to endpoint: NWEndpoint, name: String) {
        disconnect()
        host = name
        status = "Connecting to \(name)…"
        open(endpoint, name: name)
    }

    func disconnect() {
        drop()
        player.stopControlling()
        isControlling = false
        host = nil
        status = ""
    }

    private func open(_ endpoint: NWEndpoint, name: String) {
        let connection = RemoteConnection(to: endpoint)
        self.connection = connection
        let nonce = RemotePairing.nonce()
        let hello = RemoteMessage.Hello(controllerID: Remote.id, name: Remote.name, nonce: nonce)
        connection.onReady = { connection.send(.hello(hello)) }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, connection === self.connection else { return }
            switch message {
            case let .challenge(hostID, hostNonce, proof):
                guard let key = Remote.hostKeys.key(for: hostID),
                      RemotePairing.matches(proof, RemotePairing.connectProof(key, by: .host, controllerNonce: nonce,
                                                                              hostNonce: hostNonce)) else {
                    // This Mac has forgotten the Host, or the Host isn't the one it paired with: pair again.
                    Remote.hostKeys.remove(hostID)
                    return self.pair(endpoint, name: name)
                }
                connection.send(.proof(RemotePairing.connectProof(key, by: .controller, controllerNonce: nonce,
                                                                  hostNonce: hostNonce)))
                connection.encrypt(with: RemotePairing.sessionKey(key, controllerNonce: nonce, hostNonce: hostNonce))
                self.player.startControlling(RemoteLink(host: name, connection: connection))
                self.isControlling = true
                self.status = "Controlling \(name)"
            case .denied("unpaired"):
                self.pair(endpoint, name: name)
            case let .denied(reason):
                self.ended("\(name) said no: \(reason)")
            case .status, .playlist, .equalizer, .notice:
                self.player.mirror(message, host: name)
            default:
                break
            }
        }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, let connection, connection === self.connection else { return }
            self.ended(reason.map { "Lost \(name): \($0)" } ?? "\(name) closed the connection")
        }
        connection.start()
    }

    /// Pairs with the Host: it shows a Pairing Code, and the user types it here. Then connects as usual.
    private func pair(_ endpoint: NWEndpoint, name: String) {
        drop()
        let connection = RemoteConnection(to: endpoint)
        self.connection = connection
        status = "Pairing with \(name)…"
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteMessage.Hello(controllerID: Remote.id, name: Remote.name, nonce: RemotePairing.nonce())
        var secret: SymmetricKey?
        var pairedHost: String?
        connection.onReady = { connection.send(.pairRequest(hello, publicKey: privateKey.publicKey.rawRepresentation)) }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, connection === self.connection else { return }
            switch message {
            case let .pairChallenge(hostID, publicKey):
                guard let code = self.askForCode(name),
                      let agreed = try? RemotePairing.pairingSecret(privateKey, peer: publicKey, code: code) else {
                    return self.disconnect()
                }
                secret = agreed
                pairedHost = hostID
                connection.send(.pairProof(RemotePairing.pairingProof(agreed, by: .controller)))
            case let .paired(proof):
                guard let secret, let pairedHost,
                      RemotePairing.matches(proof, RemotePairing.pairingProof(secret, by: .host)) else {
                    return self.ended("\(name) couldn't prove it saw the same code")
                }
                Remote.hostKeys.set(RemotePairing.pairingKey(secret), for: pairedHost, label: name)
                self.drop()
                self.status = "Connecting to \(name)…"
                self.open(endpoint, name: name)
            case let .denied(reason):
                self.ended("Couldn't pair with \(name): \(reason)")
            default:
                break
            }
        }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, let connection, connection === self.connection else { return }
            self.ended(reason.map { "Lost \(name): \($0)" } ?? "\(name) closed the connection")
        }
        connection.start()
    }

    /// Ends the control or the try at it, saying why.
    private func ended(_ why: String) {
        drop()
        player.stopControlling()
        isControlling = false
        host = nil
        status = why
    }

    /// Closes the connection without reporting it as lost.
    private func drop() {
        let open = connection
        connection = nil
        open?.close(nil)
    }

    private func askForCode(_ name: String) -> String? {
        #if DEBUG
        if let code = ProcessInfo.processInfo.environment["BITMACHINE_PAIRING_CODE"] { return code }
        #endif
        let alert = NSAlert()
        alert.messageText = "Pair with \(name)"
        alert.informativeText = "Type the code \(name) is showing."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "0000"
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.filter(\.isNumber)
        return code.isEmpty ? nil : code
    }
}
