import AudioToolbox
import Foundation
import Testing
@testable import BitMachineKit

@Suite struct FrequencyTests {
    @Test func theSameStreamAlwaysGetsTheSameFrequency() {
        let url = URL(string: "https://ice2.somafm.com/groovesalad-128-mp3")!
        // Pinned (FNV-1a of the URL), so a change to the hash, which would move every Station on the dial, fails here.
        #expect(Frequency(for: url).description == "87.7")
    }

    @Test func everyFrequencyIsOnTheFMDial() {
        for i in 0 ..< 500 {
            let f = Frequency(for: URL(string: "http://radio\(i).example/live")!)
            #expect((875 ... 1079).contains(f.tenths))
            #expect((0 ... 1).contains(f.dialPosition))
        }
    }

    @Test func differentStreamsSpreadAcrossTheDial() {
        let all = Set((0 ..< 200).map { Frequency(for: URL(string: "http://radio\($0).example/live")!).tenths })
        #expect(all.count > 100)
    }

    @Test func showsAsMegahertz() {
        #expect(Frequency(tenths: 943).description == "94.3")
        #expect(Frequency(tenths: 1079).description == "107.9")
        #expect(Frequency(tenths: 2000).tenths == 1079)
    }
}

@Suite struct RadioPresetsTests {
    @Test func holdsSixSlotsAndFindsAStation() throws {
        var presets = RadioPresets()
        let station = Station(name: "One", url: URL(string: "http://one.example/s")!)
        presets[2] = station
        presets[9] = station
        #expect(presets.slots.count == 6)
        #expect(presets.slot(of: station.url) == 2)
        let back = try JSONDecoder().decode(RadioPresets.self, from: JSONEncoder().encode(presets))
        #expect(back == presets)
    }
}

@Suite struct IcyDemuxerTests {
    /// A stream with metadata every `interval` bytes, as a server sends it.
    private func stream(interval: Int, audio: [UInt8], titles: [String]) -> Data {
        var out = Data()
        var rest = audio[...]
        var titles = titles[...]
        while !rest.isEmpty {
            out.append(contentsOf: rest.prefix(interval))
            rest = rest.dropFirst(interval)
            if let title = titles.popFirst() {
                var block = Data("StreamTitle='\(title)';".utf8)
                let blocks = (block.count + 15) / 16
                block.append(Data(count: blocks * 16 - block.count))
                out.append(UInt8(blocks))
                out.append(block)
            } else {
                out.append(0)
            }
        }
        return out
    }

    @Test func separatesAudioFromTitlesHoweverTheChunksSplit() {
        let audio = (0 ..< 96).map { UInt8($0) } // whole intervals, as a server sends
        let data = stream(interval: 16, audio: audio, titles: ["Artist - It's a Song", "", "Next"])
        for chunk in [1, 3, 7, 16, 17, 1000] {
            var demuxer = IcyDemuxer(metaInterval: 16)
            var heard = Data()
            var titles: [String] = []
            var i = 0
            while i < data.count {
                let (a, t) = demuxer.push(data[i ..< min(i + chunk, data.count)])
                heard.append(a)
                titles += t
                i += chunk
            }
            #expect(Array(heard) == audio, "chunk \(chunk)")
            #expect(titles == ["Artist - It's a Song", "", "Next"], "chunk \(chunk)")
        }
    }

    @Test func withoutAnIntervalEverythingIsAudio() {
        var demuxer = IcyDemuxer(metaInterval: nil)
        let (audio, titles) = demuxer.push(Data([1, 2, 3]))
        #expect(audio == Data([1, 2, 3]))
        #expect(titles.isEmpty)
    }

    @Test func readsLatin1TitlesToo() {
        var block = Data("StreamTitle='Bj".utf8)
        block.append(0xF6) // ö in Latin-1, invalid on its own in UTF-8
        block.append(Data("rk';".utf8))
        #expect(IcyDemuxer.streamTitle(in: block) == "Björk")
        #expect(IcyDemuxer.streamTitle(in: Data("StreamTitle='Björk';StreamUrl='';".utf8)) == "Björk")
        #expect(IcyDemuxer.streamTitle(in: Data("StreamUrl='x';".utf8)) == nil)
    }
}

@Suite struct StationDirectoryTests {
    @Test func keepsOnlyStreamsBitMachineCanPlay() throws {
        let json = """
        [
          {"stationuuid":"a","name":" Groove Salad ","url":"https://somafm.com/gs.pls","url_resolved":"https://ice2.somafm.com/groovesalad-128-mp3","codec":"MP3","bitrate":128,"hls":0,"tags":"chillout,ambient","country":"US"},
          {"stationuuid":"b","name":"An HLS one","url_resolved":"https://x.example/live.m3u8","codec":"AAC","bitrate":64,"hls":1},
          {"stationuuid":"c","name":"Ogg","url_resolved":"https://x.example/ogg","codec":"OGG","bitrate":128,"hls":0},
          {"stationuuid":"d","name":"Still a playlist","url_resolved":"http://x.example/listen.pls","codec":"MP3","hls":0},
          {"stationuuid":"e","name":"","url_resolved":"http://aac.example/live","codec":"aac+","bitrate":48,"hls":0},
          {"stationuuid":"f","name":"Duplicate","url_resolved":"https://ice2.somafm.com/groovesalad-128-mp3","codec":"MP3","hls":0}
        ]
        """
        let stations = try StationDirectory.decode(Data(json.utf8))
        #expect(stations.map(\.name) == ["Groove Salad", "aac.example"])
        #expect(stations[0].directoryID == "a")
        #expect(stations[0].bitrate == 128)
        #expect(stations[1].codec == "AAC+")
        #expect(stations[0].track.source == .station(URL(string: "https://ice2.somafm.com/groovesalad-128-mp3")!))
        #expect(stations[0].track.duration == nil)
    }

    @Test func searchAsksForTheMostPlayedFirst() {
        let url = StationDirectory.searchURL(server: "de1.api.radio-browser.info", field: "name", term: "jazz fm", limit: 50)
        #expect(url.host() == "de1.api.radio-browser.info")
        #expect(url.query()?.contains("name=jazz%20fm") == true)
        #expect(url.query()?.contains("order=clickcount") == true)
        #expect(url.query()?.contains("hidebroken=true") == true)
    }
}

@Suite struct StreamDecoderTests {
    /// One second of a stereo sine, encoded as ADTS AAC, as an AAC station sends it.
    private func adtsSine(seconds: Double = 1, rate: Double = 44100) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitmachine-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        var aac = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                              mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var file: ExtAudioFileRef?
        #expect(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &aac, nil,
                                          AudioFileFlags.eraseFile.rawValue, &file) == noErr)
        var pcm = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm)
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for f in 0 ..< frames {
            let s = Float(sin(2 * Double.pi * 440 * Double(f) / rate)) * 0.5
            samples[2 * f] = s
            samples[2 * f + 1] = s
        }
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            #expect(ExtAudioFileWrite(file!, UInt32(frames), &list) == noErr)
        }
        ExtAudioFileDispose(file!)
        return try Data(contentsOf: url)
    }

    @Test func decodesAACArrivingInSmallChunks() throws {
        let data = try adtsSine()
        var frames = 0
        var loudest: Float = 0
        var rates = Set<Double>()
        let decoder = try StreamDecoder(kind: .aac) { samples, count, rate in
            frames += count
            rates.insert(rate)
            for i in 0 ..< count * 2 { loudest = max(loudest, abs(samples[i])) }
        }
        var i = 0
        while i < data.count {
            try decoder.feed(data[i ..< min(i + 517, data.count)])
            i += 517
        }
        #expect(decoder.sampleRate == 44100)
        #expect(rates == [44100])
        // Nearly the whole second: the decoder holds back a little, and the encoder pads the start.
        #expect(frames > 40000)
        #expect(loudest > 0.3)
    }

    @Test func garbageDoesNotCrashIt() throws {
        let decoder = try StreamDecoder(kind: nil) { _, _, _ in }
        var rng = SplitMix(seed: 7)
        for _ in 0 ..< 20 {
            // Either an error or nothing decoded is fine; the point is that it survives.
            try? decoder.feed(Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }))
        }
    }

    @Test func contentTypesNameTheKind() {
        #expect(StreamDecoder.Kind(contentType: "audio/mpeg") == .mp3)
        #expect(StreamDecoder.Kind(contentType: "audio/aacp; charset=x") == .aac)
        #expect(StreamDecoder.Kind(contentType: "application/ogg") == nil)
    }
}
