import BitMachineKit
import Foundation
import os

/// Plays a Station: streams it, takes out the ICY metadata, decodes the audio and plays it through BitMachine's
/// AudioOutput, so volume, balance, the equalizer and the visualizer work as for every Source (ADR 0004).
/// A Station is live: pausing disconnects, and resuming tunes in again, to what's on now.
@MainActor
final class StationEngine {
    struct Info: Equatable {
        var kbps: Int?
        var khz: Int?
        var stereo = true
    }

    /// The StreamTitle, as the station changes it ("" when it clears it).
    var onTitle: ((String) -> Void)?
    var onInfo: ((Info) -> Void)?
    /// The stream stopped by itself, after it had started.
    var onDropped: ((Error?) -> Void)?

    private let output: AudioOutput
    private var connection: StationConnection?
    private let log = Logger(subsystem: "tech.phin.bitmachine", category: "station")

    init(output: AudioOutput) {
        self.output = output
    }

    /// How full the buffer is, 0...1 (1 is a second or more waiting): the tuner's signal meter.
    var signal: Double { connection?.signal ?? 0 }

    var isPlaying: Bool { connection != nil }

    /// Tunes in; returns once the first audio is playing, or throws if it doesn't start.
    func play(_ url: URL) async throws {
        stop()
        let connection = StationConnection(url: url)
        self.connection = connection
        connection.onTitle = { [weak self] title in
            Task { @MainActor in self?.onTitle?(title) }
        }
        connection.onEnd = { [weak self, weak connection] error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.log.error("station dropped: \(String(describing: error), privacy: .public)")
                self.stop()
                self.onDropped?(error)
            }
        }
        let started = try await connection.start()
        guard self.connection === connection else { throw CancellationError() }
        try output.play(started.ring, sampleRate: started.sampleRate)
        onInfo?(Info(kbps: started.kbps, khz: Int((started.sampleRate / 1000).rounded()), stereo: started.stereo))
    }

    func stop() {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        output.stopRing()
    }
}

/// One connection to a stream, on its own queue: the bytes come in, the ICY metadata comes out, the rest is decoded
/// into a ring the AudioOutput reads.
final class StationConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Started {
        let ring: AudioRing
        let sampleRate: Double
        let kbps: Int?
        let stereo: Bool
    }

    enum StationError: LocalizedError {
        case status(Int)
        case notAudio(String)
        case silent

        var errorDescription: String? {
            switch self {
            case let .status(code): "The station answered \(code)"
            case let .notAudio(type): "The station sends \(type), not MP3 or AAC"
            case .silent: "The station sent no audio BitMachine can play"
            }
        }
    }

    var onTitle: ((String) -> Void)?
    var onEnd: ((Error?) -> Void)?

    private let url: URL
    private let queue = OperationQueue()
    private var session: URLSession?
    private var demuxer = IcyDemuxer(metaInterval: nil)
    private var decoder: StreamDecoder?
    private var ring: AudioRing?
    private var kbps: Int?
    private var waiting: CheckedContinuation<Started, Error>?
    private var cancelled = false
    private let state = OSAllocatedUnfairLock(initialState: (ring: AudioRing?.none, prefill: 1))

    init(url: URL) {
        self.url = url
        queue.maxConcurrentOperationCount = 1
        queue.name = "tech.phin.bitmachine.station"
    }

    var signal: Double {
        let (ring, prefill) = state.withLock { ($0.ring, $0.prefill) }
        guard let ring else { return 0 }
        return min(Double(ring.available) / Double(prefill), 1)
    }

    func start() async throws -> Started {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    waiting = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 15
                    // A stream never finishes; only silence should time it out.
                    config.timeoutIntervalForResource = .infinity
                    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    var request = URLRequest(url: url)
                    request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
                    request.setValue(StationDirectory.userAgent, forHTTPHeaderField: "User-Agent")
                    session?.dataTask(with: request).resume()
                    // A station that connects but sends nothing BitMachine can decode would otherwise wait forever.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                        self?.queue.addOperation { [weak self] in
                            guard let self, self.waiting != nil, !self.cancelled else { return }
                            self.fail(StationError.silent)
                        }
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            cancelled = true
            session?.invalidateAndCancel()
            session = nil
            finishStart(.failure(CancellationError()))
        }
    }

    private func finishStart(_ result: Result<Started, Error>) {
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(with: result)
    }

    // MARK: URLSessionDataDelegate (on `queue`)

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        if let http, !(200 ..< 300).contains(http.statusCode) {
            finishStart(.failure(StationError.status(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        let header = { (name: String) in http?.value(forHTTPHeaderField: name) }
        let type = header("Content-Type") ?? response.mimeType
        let kind = StreamDecoder.Kind(contentType: type)
        if kind == nil, let type, !type.isEmpty, !type.hasPrefix("audio/"), type != "application/octet-stream" {
            finishStart(.failure(StationError.notAudio(type)))
            completionHandler(.cancel)
            return
        }
        demuxer = IcyDemuxer(metaInterval: header("icy-metaint").flatMap { Int($0) })
        kbps = header("icy-br").flatMap { Int($0.split(separator: ",").first ?? "") }
        do {
            decoder = try StreamDecoder(kind: kind) { [weak self] samples, frames, rate in
                self?.heard(samples, frames: frames, rate: rate)
            }
            completionHandler(.allow)
        } catch {
            finishStart(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        let (audio, titles) = demuxer.push(data)
        for title in titles { onTitle?(title) }
        do {
            try decoder?.feed(audio)
        } catch {
            fail(error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        fail(error ?? (ring == nil ? StationError.silent : nil))
    }

    private func fail(_ error: Error?) {
        cancelled = true
        session?.invalidateAndCancel()
        session = nil
        if waiting != nil { finishStart(.failure(error ?? StationError.silent)) } else { onEnd?(error) }
    }

    private func heard(_ samples: UnsafePointer<Float>, frames: Int, rate: Double) {
        if ring == nil {
            // Servers send a burst of several seconds on connect, so there's room for that, and a second waits
            // before playing, to ride out the network. It never skips ahead: a station's pace is real time.
            let second = Int(rate)
            let ring = AudioRing(capacityFrames: second * 12, prefill: second)
            self.ring = ring
            state.withLock { $0 = (ring, second) }
            finishStart(.success(Started(ring: ring, sampleRate: rate, kbps: kbps, stereo: (decoder?.channels ?? 2) > 1)))
        }
        ring?.write(frames: frames) { f, c in samples[2 * f + c] }
    }
}
