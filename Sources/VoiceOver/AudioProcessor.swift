import AVFoundation
import Foundation

enum VoiceStyle: String, CaseIterable, Identifiable {
    case western = "Western", documentary = "Documentary", calm = "Calm", hollywood = "Hollywood"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .western: return "Deep & warm"
        case .documentary: return "Rich narrator"
        case .calm: return "Soft & steady"
        case .hollywood: return "Cinematic"
        }
    }
    var pitch: Float {
        switch self {
        case .western: return -320
        case .documentary: return -140
        case .calm: return -60
        case .hollywood: return -190
        }
    }
    var bass: Float {
        switch self {
        case .western: return 4
        case .documentary: return 2.5
        case .calm: return 0.5
        case .hollywood: return 2
        }
    }
    var presence: Float {
        switch self {
        case .western: return -1
        case .documentary: return 2.5
        case .calm: return -3
        case .hollywood: return 1
        }
    }
}

enum VoiceGender: String, CaseIterable, Identifiable {
    case female = "Female"
    case male = "Male"
    var id: String { rawValue }
}

extension VoiceStyle {
    func sampleFile(for gender: VoiceGender) -> (name: String, ext: String) {
        switch (gender, self) {
        case (.female, .western): return ("western-female-natural_000", "wav")
        case (.female, .documentary): return ("documentary-female-distinct_000", "wav")
        case (.female, .calm): return ("calm-female-soft-steady_000", "wav")
        case (.female, .hollywood): return ("hollywood-female-bold_000", "wav")
        case (.male, .western): return ("western-male-lead", "m4a")
        case (.male, .documentary): return ("documentary-male-light-british", "m4a")
        case (.male, .calm): return ("calm-male-warm_000", "wav")
        case (.male, .hollywood): return ("hollywood-male_000", "wav")
        }
    }
}

enum VoiceSpeed: Double, CaseIterable, Identifiable {
    case quarter = 0.25, half = 0.5, threeQuarter = 0.75, normal = 1
    case oneQuarter = 1.25, oneHalf = 1.5, oneThreeQuarter = 1.75, double = 2
    var id: Double { rawValue }
    var label: String { String(format: "%g×", rawValue) }
}

enum AudioFailure: LocalizedError {
    case empty, render, cancelled
    var errorDescription: String? {
        switch self {
        case .empty: return "This recording contains no audio. Record a little longer and try again."
        case .render: return "Audio processing could not finish. Your original recording is safe; please try again."
        case .cancelled: return "Audio processing was cancelled."
        }
    }
}

enum AudioProcessor {
    static let sampleRate: Double = 48_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    static func waveformLevels(from source: URL, samplesPerSecond: Double) throws -> [Float] {
        let input = try AVAudioFile(forReading: source)
        let framesPerLevel = AVAudioFrameCount(max(1, input.processingFormat.sampleRate / samplesPerSecond))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: framesPerLevel) else { throw AudioFailure.render }
        var levels: [Float] = []
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: min(framesPerLevel, AVAudioFrameCount(input.length - input.framePosition)))
            guard buffer.frameLength > 0 else { break }
            var peak: Float = 0
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
                }
            } else if let channels = buffer.int16ChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, Float(abs(Int(channels[channel][frame]))) / Float(Int16.max)) }
                }
            } else if let channels = buffer.int32ChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, Float(abs(Int64(channels[channel][frame]))) / Float(Int32.max)) }
                }
            }
            levels.append(peak < 0.002 ? 0 : min(1, pow(peak, 0.45)))
        }
        return levels
    }

    /// Writes an adjacent staging file before atomically replacing the chosen destination.
    static func export(source: URL, destination: URL, reduceNoise: Bool, style: VoiceStyle? = nil, speed: VoiceSpeed = .normal) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw NSError(domain: "VoiceOver", code: 10, userInfo: [NSLocalizedDescriptionKey: "Choose a different filename to preserve the original recording."])
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("VoiceOver-process-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let cleaned = scratch.appendingPathComponent("clean.caf")
        try preprocess(source: source, destination: cleaned, reduceNoise: reduceNoise, soften: style == .calm)
        var intermediate = cleaned
        if style != nil || speed != .normal {
            intermediate = scratch.appendingPathComponent("styled.caf")
            try shape(source: cleaned, destination: intermediate, style: style, speed: speed)
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".VoiceOver-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? fm.removeItem(at: stage) }
        try encode(source: intermediate, destination: stage, wav: destination.pathExtension.lowercased() == "wav")
        let check = try AVAudioFile(forReading: stage)
        guard check.length > 0 else { throw AudioFailure.empty }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }

    /// Gentle high-pass filter plus a smooth downward expander: reduces rumble and quiet background noise.
    private static func preprocess(source: URL, destination: URL, reduceNoise: Bool, soften: Bool) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw AudioFailure.empty }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw AudioFailure.render }
        var readError: Error?
        var previousInput: Float = 0, highpass: Float = 0, envelope: Float = 0, gain: Float = 1
        let alpha = Float(exp(-2 * Double.pi * 90 / sampleRate))
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                do {
                    guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
                    try input.read(into: readBuffer)
                    if readBuffer.frameLength == 0 { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return readBuffer
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw AudioFailure.render }
            if let samples = converted.floatChannelData?[0] {
                for i in 0..<Int(converted.frameLength) {
                    var x = samples[i]
                    if reduceNoise {
                        highpass = alpha * (highpass + x - previousInput)
                        previousInput = x
                        x = highpass
                        let coefficient: Float = abs(x) > envelope ? 0.025 : 0.00025
                        envelope += coefficient * (abs(x) - envelope)
                        let desired = min(1, max(0.15, envelope / 0.014))
                        gain += (desired > gain ? 0.02 : 0.0004) * (desired - gain)
                        x *= gain
                    }
                    if soften { x = tanh(x * 1.3) / 1.3 }
                    samples[i] = x
                }
            }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .endOfStream { break }
        }
    }

    private static func shape(source: URL, destination: URL, style: VoiceStyle?, speed: VoiceSpeed) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = style?.pitch ?? 0
        pitch.rate = Float(speed.rawValue)
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        eq.globalGain = style == nil ? 0 : -2
        let low = eq.bands[0]
        low.filterType = .lowShelf; low.frequency = 180; low.gain = style?.bass ?? 0; low.bypass = false
        let presence = eq.bands[1]
        presence.filterType = .parametric; presence.frequency = 2800; presence.bandwidth = 1.5; presence.gain = style?.presence ?? 0; presence.bypass = false
        let cut = eq.bands[2]
        cut.filterType = .highShelf; cut.frequency = 7500; cut.gain = style == nil ? 0 : (style == .calm ? -4 : -1); cut.bypass = false
        engine.attach(player); engine.attach(pitch); engine.attach(eq)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        player.scheduleFile(input, at: nil)
        try engine.start()
        player.play()
        defer { player.stop(); engine.stop() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { throw AudioFailure.render }
        let outputFrames = AVAudioFramePosition((Double(input.length) / speed.rawValue).rounded())
        var stalls = 0
        while engine.manualRenderingSampleTime < outputFrames {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(4096, outputFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                stalls = 0
                if let samples = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { samples[i] = max(-0.98, min(0.98, samples[i])) }
                }
                try output.write(from: buffer)
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalls += 1
                if stalls > 100 { throw AudioFailure.render }
            case .error: throw AudioFailure.render
            @unknown default: throw AudioFailure.render
            }
        }
    }

    private static func encode(source: URL, destination: URL, wav: Bool) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = wav ? [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ] : [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096) else { throw AudioFailure.render }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }
}
