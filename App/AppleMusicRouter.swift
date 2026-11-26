import BitMachineKit
import Darwin
import Foundation
import os

/// Takes over Apple Music's audio (ADR 0003): taps the process MusicKit plays in, muted, and plays what it hears
/// through BitMachine's AudioOutput, so volume, balance and the equalizer apply. If the tap hears nothing at all
/// (most likely no System Audio Recording permission), it lets go, so the music is never left silent.
@MainActor
final class AppleMusicRouter {
    enum State: Equatable {
        case off
        case routed
        /// The tap heard nothing; Apple Music plays unrouted until BitMachine is relaunched.
        case unavailable(String)
    }

    private(set) var state = State.off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?

    private let output: AudioOutput
    private var tap: ProcessTap?
    private var tappedPID: pid_t?
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: "tech.phin.bitmachine", category: "router")

    static let playerProcess = "com.apple.MediaPlayer.RemotePlayerService"

    init(output: AudioOutput) {
        self.output = output
    }

    /// Call once MusicKit is playing. Finds BitMachine's player process and taps it, unless it's tapped already.
    func start() async {
        switch AudioCapturePermission.status {
        case .denied:
            stop()
            state = .unavailable("allow System Audio Recording in BitMachine ▸ Permissions…")
            return
        case .allowed:
            // Allowed since the tap last gave up: try again.
            if case .unavailable = state { state = .off }
        case .notAsked:
            if case .unavailable = state { return }
        }
        guard let process = await findPlayerProcess() else {
            log.error("no \(Self.playerProcess, privacy: .public) is playing for BitMachine; Apple Music plays unrouted")
            return
        }
        if tap != nil, tappedPID == process.pid { return }
        stop()

        let heard = OSAllocatedUnfairLock(initialState: false)
        // About 20 ms to start, never more than about 85 ms behind (at 48 kHz).
        let ring = AudioRing(capacityFrames: 16384, prefill: 1024, maxLatency: 4096)
        do {
            let tap = try ProcessTap(processes: [process.object], muted: true) { samples, frames in
                var loud = false
                ring.write(frames: frames) { f, c in
                    let s = samples[2 * f + c]
                    if s != 0 { loud = true }
                    return s
                }
                if loud { heard.withLock { $0 = true } }
            }
            try output.play(ring, sampleRate: tap.sampleRate)
            self.tap = tap
            tappedPID = process.pid
            state = .routed
            log.info("routing Apple Music from pid \(process.pid) at \(tap.sampleRate) Hz")
        } catch {
            log.error("couldn't tap Apple Music: \(String(describing: error), privacy: .public)")
            NSLog("BitMachine router: couldn't tap Apple Music: %@", String(describing: error))
            stop()
            state = .unavailable("\(error)")
            return
        }

        // A tap without the permission runs but hears only zeros, and its muting would leave the music silent.
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !heard.withLock({ $0 }) else { return }
            self.log.error("the tap heard nothing in 3 s; letting go (System Audio Recording not allowed?)")
            self.stop()
            self.state = .unavailable("allow System Audio Recording in BitMachine ▸ Permissions…")
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        tap?.stop()
        tap = nil
        tappedPID = nil
        output.stopRing()
        if state == .routed { state = .off }
    }

    /// MusicKit starts a player process for each app that plays; it shows up in Core Audio once it outputs sound.
    /// Prefer the one macOS says is BitMachine's.
    private func findPlayerProcess() async -> AudioProcess? {
        for _ in 0 ..< 20 {
            let candidates = HAL.processes().filter { $0.bundleID == Self.playerProcess && $0.isRunningOutput }
            if let ours = candidates.first(where: { Self.responsiblePID(for: $0.pid) == getpid() }) { return ours }
            if candidates.count == 1 { return candidates[0] }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// The app macOS holds responsible for a helper process (private, but stable for years).
    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias Function = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: Function.self)(pid)
    }
}
