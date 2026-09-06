import XCTest
import AVFoundation
@testable import VoiceOver

final class AudioProcessorTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func tone(name: String = "source.caf", amplitude: Float = 0.25, rate: Double = 48000, channels: AVAudioChannelCount = 1, duration: Double = 2) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * duration))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][i] = amplitude * Float(sin(2 * .pi * 220 * Double(i) / rate))
            }
        }
        try file.write(from: buffer)
        return url
    }
    private func samples(_ url: URL) throws -> (AVAudioFile, [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }
    private func rms(_ data: [Float]) -> Double {
        sqrt(data.reduce(0.0) { $0 + Double($1 * $1) } / Double(data.count))
    }
    func testFormatsDurationAndSourcePreservation() throws {
        let input = try tone()
        let original = try Data(contentsOf: input)
        for filtered in [false, true] {
            let output = folder.appendingPathComponent(filtered ? "filtered.wav" : "plain.m4a")
            try AudioProcessor.export(source: input, destination: output, reduceNoise: filtered)
            let (file, data) = try samples(output)
            XCTAssertEqual(file.processingFormat.sampleRate, 48000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertEqual(Double(file.length) / 48000, 2, accuracy: 0.06)
            XCTAssertGreaterThan(rms(data), 0.08)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, filtered ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testEveryPresetHasCorrectPitchAndValidAudio() throws {
        let input = try tone()
        var results = [[Float]]()
        for style in VoiceStyle.allCases {
            let output = folder.appendingPathComponent("\(style.rawValue).wav")
            try AudioProcessor.export(source: input, destination: output, reduceNoise: false, style: style)
            let (file, data) = try samples(output)
            XCTAssertEqual(file.length, 96000)
            XCTAssertTrue(data.allSatisfy { $0.isFinite && abs($0) <= 1 })
            XCTAssertGreaterThan(rms(data), 0.03)
            let stable = Array(data[24000..<72000])
            let crossings = zip(stable, stable.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let expected = 220 * pow(2, Double(style.pitch) / 1200)
            XCTAssertEqual(Double(crossings), expected, accuracy: 4, "\(style.rawValue) should shift pitch")
            results.append(data)
        }
        for i in 1..<results.count { XCTAssertNotEqual(results[0], results[i]) }
    }
    func testNoiseFilterAttenuatesQuietBackground() throws {
        let input = try tone(amplitude: 0.003)
        let raw = folder.appendingPathComponent("raw.wav")
        let filtered = folder.appendingPathComponent("filtered.wav")
        try AudioProcessor.export(source: input, destination: raw, reduceNoise: false)
        try AudioProcessor.export(source: input, destination: filtered, reduceNoise: true)
        let rawSamples = try samples(raw).1
        let cleanedSamples = try samples(filtered).1
        XCTAssertLessThan(rms(Array(cleanedSamples.suffix(48000))), rms(Array(rawSamples.suffix(48000))) * 0.4)
    }
    func testWaveformLevelsFollowAudioDurationAndAmplitude() throws {
        let input = try tone(duration: 2)
        let levels = try AudioProcessor.waveformLevels(from: input, samplesPerSecond: 20)
        XCTAssertTrue((39...41).contains(levels.count))
        XCTAssertGreaterThan(levels.max() ?? 0, 0.2)
    }
    func testAllSpeedsPreservePitchAndChangeExportDuration() throws {
        let input = try tone()
        let original = try Data(contentsOf: input)
        for speed in VoiceSpeed.allCases {
            for style in [nil] + VoiceStyle.allCases.map(Optional.some) {
                let output = folder.appendingPathComponent("speed-\(speed.rawValue)-\(style?.rawValue ?? "original").wav")
                try AudioProcessor.export(source: input, destination: output, reduceNoise: false, style: style, speed: speed)
                let (file, data) = try samples(output)
                let expectedDuration = 2 / speed.rawValue
                XCTAssertEqual(Double(file.length) / 48000, expectedDuration, accuracy: 0.001)
                XCTAssertTrue(data.allSatisfy { $0.isFinite && abs($0) <= 1 })
                let stable = Array(data[(data.count / 4)..<(data.count * 3 / 4)])
                let crossings = zip(stable, stable.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
                let frequency = Double(crossings) / (Double(stable.count) / 48000)
                XCTAssertEqual(frequency, 220 * pow(2, Double(style?.pitch ?? 0) / 1200), accuracy: 5,
                               "Pitch at \(speed.label), \(style?.rawValue ?? "original")")
                XCTAssertGreaterThan(rms(Array(data.suffix(min(4800, data.count)))), 0.02, "No silent tail at \(speed.label)")
            }
            let compressed = folder.appendingPathComponent("speed-\(speed.rawValue).m4a")
            try AudioProcessor.export(source: input, destination: compressed, reduceNoise: false, speed: speed)
            let file = try AVAudioFile(forReading: compressed)
            XCTAssertEqual(Double(file.length) / 48000, 2 / speed.rawValue, accuracy: 0.06)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testResamplingStereoSpeechInput() throws {
        let input = try tone(rate: 22050, channels: 2)
        let output = folder.appendingPathComponent("resampled.wav")
        try AudioProcessor.export(source: input, destination: output, reduceNoise: false)
        let (file, data) = try samples(output)
        XCTAssertEqual(Double(file.length) / 48000, 2, accuracy: 0.03)
        XCTAssertGreaterThan(rms(data), 0.1)
    }
    func testReplaceAndWriteFailurePreserveAudio() throws {
        let input = try tone()
        let original = try Data(contentsOf: input)
        let output = folder.appendingPathComponent("existing.m4a")
        try Data("old destination".utf8).write(to: output)
        try AudioProcessor.export(source: input, destination: output, reduceNoise: false)
        XCTAssertGreaterThan(try AVAudioFile(forReading: output).length, 0)
        let saved = try Data(contentsOf: output)
        XCTAssertThrowsError(try AudioProcessor.export(source: folder.appendingPathComponent("missing.caf"), destination: output, reduceNoise: false))
        XCTAssertEqual(try Data(contentsOf: output), saved)
        XCTAssertThrowsError(try AudioProcessor.export(source: input, destination: folder.appendingPathComponent("missing-dir/result.wav"), reduceNoise: true))
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertThrowsError(try AudioProcessor.export(source: input, destination: input, reduceNoise: false))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testEmptyInputRejected() throws {
        let empty = folder.appendingPathComponent("empty.caf")
        do { _ = try AVAudioFile(forWriting: empty, settings: AudioProcessor.format.settings) }
        XCTAssertThrowsError(try AudioProcessor.export(source: empty, destination: folder.appendingPathComponent("out.wav"), reduceNoise: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.wav").path))
    }
    func testSpeechExports() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEOVER_QA_SPEECH"] else { throw XCTSkip("Set VOICEOVER_QA_SPEECH to export a speech fixture.") }
        let input = URL(fileURLWithPath: path)
        for style in VoiceStyle.allCases {
            let output = input.deletingLastPathComponent().appendingPathComponent("\(style.rawValue).wav")
            try AudioProcessor.export(source: input, destination: output, reduceNoise: true, style: style)
            let (file, data) = try samples(output)
            XCTAssertGreaterThan(file.length, 48000)
            XCTAssertGreaterThan(rms(data), 0.001)
        }
    }
}
