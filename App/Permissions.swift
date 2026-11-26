import AppKit
import Darwin
import MusicKit
import SwiftUI

/// The two things BitMachine needs macOS to allow: Apple Music, to search and play, and System Audio Recording, to
/// route Apple Music's audio through BitMachine (ADR 0003).
@MainActor
final class Permissions: ObservableObject {
    enum Status { case allowed, denied, notAsked }

    static let shared = Permissions()

    @Published private(set) var appleMusic = Status.notAsked
    @Published private(set) var audioRecording = Status.notAsked

    var allAllowed: Bool { appleMusic == .allowed && audioRecording == .allowed }

    init() { refresh() }

    func refresh() {
        appleMusic = switch MusicAuthorization.currentStatus {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        audioRecording = AudioCapturePermission.status
    }

    func requestAppleMusic() {
        Task {
            _ = await MusicAuthorization.request()
            refresh()
            if appleMusic == .denied { openSettings("Privacy_Media") }
        }
    }

    func requestAudioRecording() {
        if audioRecording == .denied { openSettings("Privacy_AudioCapture"); return }
        AudioCapturePermission.request { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// System Audio Recording has no public API to check or ask for it; macOS's TCC framework has one, which audio tools
/// use (AudioCap, FineTune). If it's ever missing, BitMachine treats the permission as not asked, and the router's
/// watchdog still keeps the music from going silent.
enum AudioCapturePermission {
    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void

    static var status: Permissions.Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .notAsked }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .notAsked
        }
    }

    static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(symbol, to: Request.self)(service, nil, done)
    }
}

struct PermissionsView: View {
    @ObservedObject var permissions: Permissions
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BitMachine needs two things from macOS").font(.title3.bold())
            row("Apple Music", "To search Apple Music and your library, and to play.", permissions.appleMusic,
                action: permissions.requestAppleMusic)
            row("System Audio Recording",
                "Apple Music plays in a part of macOS that BitMachine can't turn up or down. With this, BitMachine "
                    + "takes that sound over and plays it itself, so the volume, balance, equalizer and visualizer "
                    + "work on Apple Music. Nothing is recorded or saved.",
                permissions.audioRecording, action: permissions.requestAudioRecording)
            HStack {
                Spacer()
                Button(permissions.allAllowed ? "Done" : "Not Now", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func row(_ title: String, _ why: String, _ status: Permissions.Status,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .allowed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .allowed ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .allowed: Text("Allowed").foregroundStyle(.secondary)
            case .notAsked: Button("Allow…", action: action)
            case .denied: Button("Open Settings…", action: action)
            }
        }
    }
}

@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?
    private static let seenKey = "permissionsSeen"

    /// Shows the window at launch until the user has dismissed it once, while something isn't allowed.
    func showAtLaunchIfNeeded() {
        Permissions.shared.refresh()
        if !Permissions.shared.allAllowed, !UserDefaults.standard.bool(forKey: Self.seenKey) { show() }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to BitMachine"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionsView(permissions: .shared) { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.seenKey)
                self?.window?.close()
            })
            window.center()
            self.window = window
        }
        Permissions.shared.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
