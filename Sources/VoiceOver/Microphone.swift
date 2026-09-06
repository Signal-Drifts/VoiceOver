import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class Microphone: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum State { case idle, requesting, recording, paused, stopped }
    @Published private(set) var state = State.idle
    @Published private(set) var seconds: TimeInterval = 0
    @Published private(set) var previewSeconds: TimeInterval = 0
    @Published private(set) var showingPreviewTime = false
    @Published private(set) var levels = Array(repeating: Float(0), count:  sixtyBars)
    @Published private(set) var busy = false
    @Published private(set) var playing = false
    @Published private(set) var previewPaused = false
    @Published private(set) var playingVoiceSampleID: String?
    @Published private(set) var voiceSamplePaused = false
    @Published var error: String?
    @Published private(set) var showingDiscardConfirmation = false
    @Published private(set) var showingCloseConfirmation = false
    @Published private(set) var showingSaveSheet = false
    @Published private(set) var saveSheetTitle = "Save Recording"
    @Published var saveFileName = ""
    @Published var saveFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    @Published var reduceNoise = false { didSet { if oldValue != reduceNoise { selectionChanged(preserveVoiceBase: false) } } }
    @Published private(set) var style: VoiceStyle?
    @Published private(set) var voiceGender: VoiceGender?
    @Published var speed: VoiceSpeed = .normal { didSet { if oldValue != speed { selectionChanged(preserveVoiceBase: true) } } }
    private var previewWorker: Task<([Float], URL?), Error>?
    private var renderingPreview = false
    private static let sixtyBars = 60
    private static let maximumRecordingSeconds: TimeInterval = 5 * 60
    nonisolated private static let waveformSamplesPerSecond: Double = 20
    private var capturedLevels: [Float] = []
    private var previewLevels: [Float] = []
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var voiceSamplePlayer: AVAudioPlayer?
    private var timer: Timer?
    private var previewTimer: Timer?
    private var closeCompletion: ((Bool) -> Void)?
    private var saveDestinationContinuation: CheckedContinuation<URL?, Never>?
    private var saveExtension = "m4a"
    @Published private(set) var source: URL?
    private var previewFile: URL?
    private var previewCacheKey: String?
    private var voiceBaseFile: URL?
    private var voiceBaseCacheKey: String?
    private var previewGeneration = UUID()
    @Published private var panelOpen = false
    var canModify: Bool { state == .stopped && source != nil }
    var canPreview: Bool { state == .stopped && source != nil }
    var canSave: Bool { state == .stopped && source != nil }
    var canDiscard: Bool { state == .stopped && source != nil }
    var canInteract: Bool { !busy && !panelOpen }
    var canInterruptPreview: Bool { !panelOpen && (!busy || renderingPreview) }
    var canPlayVoiceSample: Bool { !busy && !panelOpen && state != .recording && state != .paused && state != .requesting }
    var isModified: Bool { style != nil || speed != .normal || reduceNoise }
    var previewActive: Bool { playing || previewPaused || renderingPreview }
    var previewPreparing: Bool { renderingPreview }
    var isUnavailable: Bool { busy || panelOpen || state == .requesting }
    var hasUnsavedRecording: Bool { source != nil }
    var canRequestClose: Bool { hasUnsavedRecording && !panelOpen && state != .requesting && (!busy || previewActive) }
    var time: String {
        let n = Int(showingPreviewTime ? previewSeconds : seconds)
        return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }

    var saveFolders: [(String, URL)] {
        let manager = FileManager.default
        return [
            ("Downloads", manager.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            ("Desktop", manager.urls(for: .desktopDirectory, in: .userDomainMask).first),
            ("Documents", manager.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("Music", manager.urls(for: .musicDirectory, in: .userDomainMask).first)
        ].compactMap { name, url in url.map { (name, $0) } }
    }

    func resolveSaveSheet(save: Bool) {
        guard let continuation = saveDestinationContinuation else { return }
        saveDestinationContinuation = nil
        showingSaveSheet = false
        guard save else { continuation.resume(returning: nil); return }
        var fileName = saveFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty { fileName = "VoiceOver Recording.\(saveExtension)" }
        if (fileName as NSString).pathExtension.lowercased() != saveExtension {
            fileName = (fileName as NSString).deletingPathExtension + ".\(saveExtension)"
        }
        continuation.resume(returning: saveFolder.appendingPathComponent(fileName))
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Folder"
        panel.prompt = "Choose"
        panel.directoryURL = saveFolder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let folder = panel.url {
                self.saveFolder = folder
            }
        }
    }

    func requestCloseConfirmation(completion: @escaping (Bool) -> Void) {
        guard hasUnsavedRecording else { completion(true); return }
        stopVoiceSample()
        stopPreview()
        panelOpen = true
        closeCompletion = completion
        showingCloseConfirmation = true
    }

    func resolveCloseConfirmation(save: Bool) {
        showingCloseConfirmation = false
        panelOpen = false
        let completion = closeCompletion
        closeCompletion = nil
        if save {
            stop()
            saveRecording { [weak self] success in
                if success { self?.discard(confirm: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion?(success) }
            }
        } else {
            discard(confirm: false)
            releaseSavedDraft()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion?(true) }
        }
    }

    func selectVoiceStyle(_ selectedStyle: VoiceStyle, gender: VoiceGender) {
        let resume = playing || renderingPreview
        invalidatePreviewCache()
        invalidateVoiceBaseCache()
        if style == selectedStyle && voiceGender == gender {
            style = nil
            voiceGender = nil
        } else {
            style = selectedStyle
            voiceGender = gender
        }
        if resume { preview() }
    }

    func isVoiceStyleSelected(_ selectedStyle: VoiceStyle, gender: VoiceGender) -> Bool {
        style == selectedStyle && voiceGender == gender
    }

    func voiceSampleID(_ selectedStyle: VoiceStyle, gender: VoiceGender) -> String {
        "\(gender.rawValue)-\(selectedStyle.rawValue)"
    }

    func selectAndPlayVoice(_ selectedStyle: VoiceStyle, gender: VoiceGender) {
        guard canPlayVoiceSample else { return }
        if style == selectedStyle, voiceGender == gender {
            invalidatePreviewCache()
            invalidateVoiceBaseCache()
            stopVoiceSample()
            style = nil
            voiceGender = nil
            return
        }
        invalidatePreviewCache()
        invalidateVoiceBaseCache()
        stopVoiceSample()
        style = selectedStyle
        voiceGender = gender
        playVoiceSample(selectedStyle, gender: gender)
    }

    func playVoiceSample(_ selectedStyle: VoiceStyle, gender: VoiceGender) {
        guard canPlayVoiceSample else { return }
        let id = voiceSampleID(selectedStyle, gender: gender)
        if playingVoiceSampleID == id {
            stopVoiceSample()
            return
        }
        stopPreview()
        stopVoiceSample()
        let file = selectedStyle.sampleFile(for: gender)
        guard let url = Bundle.main.url(forResource: file.name, withExtension: file.ext, subdirectory: "Voice") else {
            error = "The \(gender.rawValue.lowercased()) \(selectedStyle.rawValue) sample is unavailable."
            return
        }
        do {
            let playback = try AVAudioPlayer(contentsOf: url)
            playback.delegate = self
            guard playback.prepareToPlay(), playback.play() else { throw AudioFailure.render }
            voiceSamplePlayer = playback
            playingVoiceSampleID = id
            voiceSamplePaused = false
        } catch {
            self.error = "Could not play this voice sample. \(error.localizedDescription)"
        }
    }

    func stopVoiceSample() {
        voiceSamplePlayer?.stop()
        voiceSamplePlayer = nil
        playingVoiceSampleID = nil
        voiceSamplePaused = false
    }

    func start() {
        guard state == .idle, !isUnavailable else { return }
        stopVoiceSample()
        invalidatePreviewCache()
        invalidateVoiceBaseCache()
        previewSeconds = 0
        showingPreviewTime = false
        state = .requesting
        Task {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard granted else {
                state = .idle
                error = "Enable VoiceOver in System Settings → Privacy & Security → Microphone."
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver-recording-\(UUID().uuidString).caf")
            do {
                let capture = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false
                ])
                capture.delegate = self
                capture.isMeteringEnabled = true
                guard capture.prepareToRecord(), capture.record() else { throw AudioFailure.render }
                recorder = capture
                source = url
                seconds = 0
                capturedLevels = []
                previewLevels = []
                self.style = nil
                self.voiceGender = nil
                self.speed = .normal
                levels = Array(repeating: 0, count: Self.sixtyBars)
                state = .recording
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.state == .recording, let recorder = self.recorder else { return }
                        self.seconds = min(recorder.currentTime, Self.maximumRecordingSeconds)
                        recorder.updateMeters()
                        let power = recorder.averagePower(forChannel: 0)
                        self.capturedLevels.append(power < -55 ? 0 : min(1, pow(10, power / 30)))
                        self.levels = self.summarized(self.capturedLevels)
                        if recorder.currentTime >= Self.maximumRecordingSeconds { self.stop() }
                    }
                }
            } catch {
                self.error = error.localizedDescription
                source = nil
                state = .idle
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func pauseOrResume() {
        guard !isUnavailable, let recorder else { return }
        if state == .recording {
            seconds = recorder.currentTime
            recorder.pause()
            state = .paused
        } else if state == .paused {
            if recorder.record() { state = .recording }
            else { error = "The microphone could not resume. Your recording is still available." }
        }
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        seconds = recorder?.currentTime ?? seconds
        state = .stopped
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
    }

    func saveRecording(modified: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard state == .stopped, let source, !isUnavailable else { completion(false); return }
        stopPreview()
        let filtered = modified && reduceNoise
        let speed: VoiceSpeed = modified ? self.speed : .normal
        let style: VoiceStyle? = modified ? self.style : nil
        let target = modified ? voiceTargetURL(style: style, gender: voiceGender) : nil
        if style != nil && target == nil {
            error = VoiceConversionFailure.referenceUnavailable.localizedDescription
            completion(false)
            return
        }
        let suffix = [style?.rawValue, speed == .normal ? nil : speed.label].compactMap { $0 }.joined(separator: " — ")
        let name = "VoiceOver \(Self.dateName())" + (suffix.isEmpty ? "" : " — \(suffix)")
        let cachedPreview = modified && previewCacheKey == currentPreviewKey ? previewFile : nil
        let cachedBase = modified && voiceBaseCacheKey == currentVoiceBaseKey ? voiceBaseFile : nil
        panelOpen = true
        Task {
            guard let destination = await chooseDestination(name: name, wav: modified, title: modified ? "Save Modified" : "Save Original") else {
                completion(false)
                return
            }
            busy = true
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let cachedPreview {
                        try AudioProcessor.export(source: cachedPreview, destination: destination, reduceNoise: false)
                    } else if let cachedBase {
                        try VoiceConverter.render(base: cachedBase, destination: destination, speed: speed)
                    } else {
                        try await VoiceConverter.render(source: source, target: target, destination: destination, reduceNoise: filtered, speed: speed)
                    }
                }.value
                busy = false
                completion(true)
            } catch {
                busy = false
                self.error = "Could not save recording. \(error.localizedDescription) Your recording is still available."
                completion(false)
            }
        }
    }

    func discard(confirm: Bool = true) {
        guard !panelOpen, (!busy || renderingPreview), hasUnsavedRecording else { return }
        if confirm {
            stopPreview()
            panelOpen = true
            showingDiscardConfirmation = true
            return
        }
        invalidatePreviewCache()
        invalidateVoiceBaseCache()
        stop()
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
        style = nil
        voiceGender = nil
        speed = .normal
        capturedLevels = []
        previewLevels = []
        reset()
    }

    func resolveDiscardConfirmation(discardRecording: Bool) {
        showingDiscardConfirmation = false
        panelOpen = false
        if discardRecording { discard(confirm: false) }
    }

    private func reset() {
        state = .idle
        seconds = 0
        previewSeconds = 0
        showingPreviewTime = false
        levels = Array(repeating: 0, count: Self.sixtyBars)
    }

    func preview() {
        if previewActive { stopPreview(); return }
        guard !panelOpen, canPreview, let source else { return }
        stopVoiceSample()
        let key = currentPreviewKey
        if previewCacheKey == key, let previewFile, FileManager.default.fileExists(atPath: previewFile.path) {
            playPreview(previewFile)
            return
        }
        invalidatePreviewCache()
        let filtered = reduceNoise
        let style = style
        let target = voiceTargetURL(style: style, gender: voiceGender)
        guard style == nil || target != nil else {
            error = VoiceConversionFailure.referenceUnavailable.localizedDescription
            return
        }
        let speed = speed
        let generation = UUID()
        previewGeneration = generation
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver-preview-\(generation).wav")
        let baseKey = currentVoiceBaseKey
        let cachedBase = voiceBaseCacheKey == baseKey ? voiceBaseFile : nil
        let generatedBase = cachedBase == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver-voice-base-\(generation).wav")
            : nil
        previewSeconds = 0
        showingPreviewTime = true
        busy = true
        renderingPreview = true
        let worker = Task.detached(priority: .userInitiated) {
            let base: URL
            if let cachedBase {
                base = cachedBase
            } else if let generatedBase {
                try await VoiceConverter.prepareBase(source: source, target: target, destination: generatedBase, reduceNoise: filtered)
                base = generatedBase
            } else {
                throw AudioFailure.render
            }
            try Task.checkCancellation()
            try VoiceConverter.render(base: base, destination: destination, speed: speed)
            let waveform = try AudioProcessor.waveformLevels(from: destination, samplesPerSecond: Self.waveformSamplesPerSecond)
            return (waveform, generatedBase)
        }
        previewWorker = worker
        Task {
            do {
                let (waveform, newBase) = try await worker.value
                guard previewGeneration == generation else {
                    try? FileManager.default.removeItem(at: destination)
                    if let newBase { try? FileManager.default.removeItem(at: newBase) }
                    return
                }
                busy = false
                renderingPreview = false
                previewWorker = nil
                let playback = try AVAudioPlayer(contentsOf: destination)
                playback.delegate = self
                guard playback.prepareToPlay(), playback.play() else { throw AudioFailure.render }
                player = playback
                previewFile = destination
                previewCacheKey = key
                if let newBase {
                    if let voiceBaseFile { try? FileManager.default.removeItem(at: voiceBaseFile) }
                    voiceBaseFile = newBase
                    voiceBaseCacheKey = baseKey
                }
                previewLevels = waveform
                previewSeconds = 0
                playing = true
                previewPaused = false
                startPreviewTimer()
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if let generatedBase { try? FileManager.default.removeItem(at: generatedBase) }
                guard previewGeneration == generation else { return }
                busy = false
                renderingPreview = false
                previewWorker = nil
                showingPreviewTime = false
                self.error = "Could not preview voice. \(error.localizedDescription)"
            }
        }
    }

    private func selectionChanged(preserveVoiceBase: Bool) {
        let resume = playing || renderingPreview
        invalidatePreviewCache()
        if !preserveVoiceBase { invalidateVoiceBaseCache() }
        if resume { preview() }
    }

    func stopPreview() {
        previewGeneration = UUID()
        previewWorker?.cancel()
        previewWorker = nil
        if renderingPreview { busy = false; renderingPreview = false }
        player?.stop()
        player = nil
        previewTimer?.invalidate()
        previewTimer = nil
        playing = false
        previewPaused = false
        levels = summarized(capturedLevels)
    }

    private var currentPreviewKey: String {
        "\(source?.standardizedFileURL.path ?? "")|\(style?.rawValue ?? "Original")|\(voiceGender?.rawValue ?? "Original")|\(speed.rawValue)|\(reduceNoise)"
    }

    private var currentVoiceBaseKey: String {
        "\(source?.standardizedFileURL.path ?? "")|\(style?.rawValue ?? "Original")|\(voiceGender?.rawValue ?? "Original")|\(reduceNoise)"
    }

    private func voiceTargetURL(style: VoiceStyle?, gender: VoiceGender?) -> URL? {
        guard let style, let gender else { return nil }
        let file = style.sampleFile(for: gender)
        return Bundle.main.url(forResource: file.name, withExtension: file.ext, subdirectory: "Voice")
    }

    private func invalidatePreviewCache() {
        stopPreview()
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
        previewFile = nil
        previewCacheKey = nil
        previewLevels = []
    }

    private func invalidateVoiceBaseCache() {
        if let voiceBaseFile { try? FileManager.default.removeItem(at: voiceBaseFile) }
        voiceBaseFile = nil
        voiceBaseCacheKey = nil
    }

    private func playPreview(_ url: URL) {
        do {
            let playback = try AVAudioPlayer(contentsOf: url)
            playback.delegate = self
            guard playback.prepareToPlay(), playback.play() else { throw AudioFailure.render }
            player = playback
            previewSeconds = 0
            showingPreviewTime = true
            playing = true
            previewPaused = false
            startPreviewTimer()
        } catch {
            invalidatePreviewCache()
            self.error = "Could not preview voice. \(error.localizedDescription)"
        }
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewActive, let player = self.player else { return }
                self.previewSeconds = player.currentTime
                let playedCount = min(self.previewLevels.count, Int(player.currentTime * Self.waveformSamplesPerSecond) + 1)
                self.levels = self.summarized(Array(self.previewLevels.prefix(playedCount)))
            }
        }
    }

    private func summarized(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: Self.sixtyBars) }
        if samples.count <= Self.sixtyBars {
            return samples + Array(repeating: 0, count: Self.sixtyBars - samples.count)
        }
        return (0..<Self.sixtyBars).map { bar in
            let start = bar * samples.count / Self.sixtyBars
            let end = max(start + 1, (bar + 1) * samples.count / Self.sixtyBars)
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }

    func pauseOrResumePreview() {
        guard let player, !renderingPreview else { return }
        if previewPaused {
            guard player.play() else {
                error = "Could not resume the preview."
                return
            }
            previewPaused = false
            playing = true
        } else if playing {
            player.pause()
            playing = false
            previewPaused = true
        }
    }

    func releaseSavedDraft() {
        stopVoiceSample()
        invalidatePreviewCache()
        invalidateVoiceBaseCache()
    }

    private func chooseDestination(name: String, wav: Bool, title: String) async -> URL? {
        panelOpen = true
        defer { panelOpen = false }
        saveSheetTitle = title
        saveExtension = wav ? "wav" : "m4a"
        saveFileName = name + ".\(saveExtension)"
        if !FileManager.default.fileExists(atPath: saveFolder.path) {
            saveFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        }
        return await withCheckedContinuation { continuation in
            saveDestinationContinuation = continuation
            showingSaveSheet = true
        }
    }

    static func dateName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "Recording was interrupted."
        Task { @MainActor in self.stop(); self.error = message }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor in
            self.stop()
            self.error = "Recording was interrupted. Save the available audio or reset it to start again."
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.previewSeconds = player.duration
                self.stopPreview()
            }
            if self.voiceSamplePlayer === player { self.stopVoiceSample() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "Playback was interrupted."
        Task { @MainActor in
            if self.player === player { self.stopPreview(); self.error = message }
            if self.voiceSamplePlayer === player { self.stopVoiceSample(); self.error = message }
        }
    }
}
