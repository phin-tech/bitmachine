import AVFoundation
import AppKit
import MusicKit
import SwiftUI

/// Spike: can a Core Audio process tap hear Apple Music played by ApplicationMusicPlayer?
///
///   open -n TapSpike.app --args control        taps a non-DRM tone, ours and afplay's (positive control)
///   open -n TapSpike.app --args applemusic [search term]
///
/// Results are appended to ~/Library/Logs/TapSpike.log. Add --quit to exit when done.
@main
struct TapSpikeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var log = Log.shared
    var body: some Scene {
        WindowGroup("TapSpike") {
            ScrollView {
                Text(log.text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).padding()
            }
            .frame(minWidth: 640, minHeight: 400)
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        Task.detached { await Spike.run(arguments: Array(CommandLine.arguments.dropFirst())) }
    }
}

@MainActor
final class Log: ObservableObject {
    static let shared = Log()
    @Published var text = ""
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TapSpike.log")

    nonisolated static func line(_ s: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
        Task { @MainActor in shared.append(stamped) }
    }

    private func append(_ s: String) {
        text += s
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
        } else {
            try? Data(s.utf8).write(to: url)
        }
    }
}

enum Spike {
    static func run(arguments: [String]) async {
        let quit = arguments.contains("--quit")
        let args = arguments.filter { $0 != "--quit" && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        let mode = args.first ?? "control"
        Log.line("=== TapSpike \(mode), pid \(getpid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        switch mode {
        case "applemusic": await appleMusic(term: args.dropFirst().joined(separator: " "))
        case "muted": await appleMusic(term: args.dropFirst().joined(separator: " "), muted: true)
        default: await control()
        }
        Log.line("=== done")
        if quit {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    // MARK: Positive control

    static func control() async {
        let engine = AVAudioEngine()
        let tone = AVAudioSourceNode { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0 ..< Int(frames) {
                let v = Float(0.25 * sin(2 * Double.pi * 440 * Double(Tone.phase) / 48000))
                Tone.phase += 1
                for b in list { b.mData!.assumingMemoryBound(to: Float.self)[frame] = v }
            }
            return noErr
        }
        engine.attach(tone)
        engine.connect(tone, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do { try engine.start() } catch { Log.line("engine start failed: \(error)"); return }
        Log.line("playing a 440 Hz tone at -12 dBFS in our own process")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await measureAll(label: "own tone")
        engine.stop()

        guard let file = writeToneFile() else { return }
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [file.path]
        do { try afplay.run() } catch { Log.line("afplay failed: \(error)"); return }
        Log.line("afplay pid \(afplay.processIdentifier) playing a 440 Hz tone at -12 dBFS")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await measureAll(label: "afplay tone", extra: [afplay.processIdentifier])
        afplay.terminate()
    }

    enum Tone { nonisolated(unsafe) static var phase = 0 }

    static func writeToneFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapspike-tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 30)
        else { Log.line("couldn't write tone file"); return nil }
        buffer.frameLength = buffer.frameCapacity
        for i in 0 ..< Int(buffer.frameLength) {
            let v = Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48000))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        do { try file.write(from: buffer) } catch { Log.line("tone write failed: \(error)"); return nil }
        return url
    }

    // MARK: Apple Music

    static func appleMusic(term: String, muted: Bool = false) async {
        let status = await MusicAuthorization.request()
        Log.line("MusicAuthorization: \(status)")
        guard status == .authorized else { return }
        do {
            let subscription = try await MusicSubscription.current
            Log.line("canPlayCatalogContent: \(subscription.canPlayCatalogContent)")
        } catch { Log.line("MusicSubscription failed: \(error)") }

        let query = term.isEmpty ? "Daft Punk One More Time" : term
        do {
            let country = (try? await MusicDataRequest.currentCountryCode) ?? "?"
            Log.line("storefront country: \(country)")
            var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(country)/search")!
            components.queryItems = [.init(name: "term", value: query), .init(name: "types", value: "songs"),
                                     .init(name: "limit", value: "1")]
            do {
                let raw = try await MusicDataRequest(urlRequest: URLRequest(url: components.url!)).response()
                Log.line("raw catalog search: HTTP \(raw.urlResponse.statusCode), \(raw.data.count) bytes: "
                    + String(decoding: raw.data.prefix(300), as: UTF8.self))
            } catch { Log.line("raw catalog search failed: \(error)") }

            var song: Song?
            do {
                var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
                request.limit = 1
                song = try await request.response().songs.first
                if song == nil { Log.line("no catalog result for \(query)") }
            } catch { Log.line("catalog search failed: \(error)") }
            if song == nil {
                var library = MusicLibraryRequest<Song>()
                library.limit = 1
                do {
                    song = try await library.response().items.first
                    Log.line(song == nil ? "Apple Music Library has no songs" : "falling back to a library song")
                } catch { Log.line("library request failed: \(error)") }
            }
            guard let song else { return }
            Log.line("playing \(song.title) by \(song.artistName) (\(song.id))")
            let player = ApplicationMusicPlayer.shared
            player.queue = [song]
            try await player.play()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            Log.line("player status: \(player.state.playbackStatus), time \(player.playbackTime)")
            let remote = HAL.processes().filter { $0.bundleID.localizedCaseInsensitiveContains("RemotePlayer") }
            if muted, let target = remote.first, let object = HAL.processObject(for: target.pid) {
                // Muted when tapped: the speakers should go quiet for 6 seconds while the tap still gets the music.
                Log.line("muting RemotePlayerService pid \(target.pid) for 6 s while tapping it")
                let result = await Task.detached { () -> String in
                    do { return try TapMeter().measure(.processes([object]), seconds: 6, muted: true).summary }
                    catch { return "error: \(error)" }
                }.value
                Log.line("[muted] tap RemotePlayerService: \(result)")
                Log.line("[muted] player status after: \(player.state.playbackStatus), time \(player.playbackTime)")
            } else {
                await measureAll(label: "Apple Music", extra: remote.map(\.pid))
            }
            player.stop()
        } catch {
            Log.line("Apple Music failed: \(error)")
        }
    }

    // MARK: Measuring

    /// Lists every process the HAL knows, then taps: our own process, each other process running output,
    /// any extra pids asked for, and a global tap.
    static func measureAll(label: String, extra: [pid_t] = []) async {
        let processes = HAL.processes()
        Log.line("[\(label)] HAL processes running output:")
        for p in processes where p.isRunningOutput {
            Log.line("   pid \(p.pid) object \(p.object) \(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID)")
        }
        var targets: [(String, TapMeter.Target)] = []
        if let own = HAL.processObject(for: getpid()) {
            targets.append(("own pid \(getpid())", .processes([own])))
        } else {
            Log.line("[\(label)] no HAL process object for our own pid")
        }
        var pids = Set(extra)
        for p in processes where p.isRunningOutput && p.pid != getpid() { pids.insert(p.pid) }
        for pid in pids.sorted() {
            guard let object = HAL.processObject(for: pid) else {
                Log.line("[\(label)] no HAL process object for pid \(pid)"); continue
            }
            let name = processes.first { $0.pid == pid }?.bundleID ?? ""
            targets.append(("pid \(pid) \(name)", .processes([object])))
        }
        targets.append(("global", .globalExcluding([])))

        for (name, target) in targets {
            let result = await Task.detached { () -> String in
                do { return try TapMeter().measure(target, seconds: 2).summary } catch { return "error: \(error)" }
            }.value
            Log.line("[\(label)] tap \(name): \(result)")
        }
    }
}
