import AVFoundation
import Foundation
import Testing
@testable import BitMachineKit

/// Writes a second-long (by default) WAV of silence.
private func writeWAV(_ url: URL, seconds: Double = 1) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                                                          AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * seconds))!
    buffer.frameLength = buffer.frameCapacity
    try file.write(from: buffer)
}

@Suite struct LocalFilesTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bitmachine-\(UUID().uuidString)")

    @Test func foldersOpenUpInFindersOrder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = folder.appendingPathComponent("Album/Disc 1")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        for name in ["10 Ten.wav", "2 Two.wav", "1 One.wav"] { try writeWAV(disc.appendingPathComponent(name)) }
        try Data("not audio".utf8).write(to: disc.appendingPathComponent("cover.jpg"))
        let loose = folder.appendingPathComponent("loose.wav")
        try writeWAV(loose)

        let files = LocalFiles.audioFiles(in: [folder.appendingPathComponent("Album"), loose,
                                               folder.appendingPathComponent("missing.mp3")])
        #expect(files.map(\.lastPathComponent) == ["1 One.wav", "2 Two.wav", "10 Ten.wav", "loose.wav"])
    }

    @Test func aFileWithoutTagsIsNamedAfterItself() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Untitled Demo.wav")
        try writeWAV(url, seconds: 2)
        let track = await LocalFiles.track(for: url)
        #expect(track.title == "Untitled Demo")
        #expect(track.source == .localFile(url))
        #expect(abs((track.duration ?? 0) - 2) < 0.05)
    }

    @Test func manyFilesKeepTheirOrder() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (1 ... 12).map { folder.appendingPathComponent("\($0).wav") }
        for url in urls { try writeWAV(url, seconds: 0.1) }
        let tracks = await LocalFiles.tracks(for: urls)
        #expect(tracks.map(\.title) == (1 ... 12).map(String.init))
    }

    /// Playing itself needs an audio device, so it's checked in the app; this is what playing reports.
    @Test func aFileReportsItsLengthAndChannels() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("short.wav")
        try writeWAV(url, seconds: 0.3)
        let info = try AudioOutput.FileInfo(of: url)
        #expect(abs(info.duration - 0.3) < 0.01)
        #expect(info.channels == 2)
        #expect(info.sampleRate == 44100)
    }
}
