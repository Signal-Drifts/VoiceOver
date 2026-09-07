import Foundation

enum VoiceConversionFailure: LocalizedError {
    case runtimeUnavailable
    case referenceUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "The local voice model is unavailable."
        case .referenceUnavailable:
            return "The selected voice sample is unavailable."
        case .conversionFailed(let detail):
            return detail.isEmpty ? "The local voice conversion failed." : "The local voice conversion failed: \(detail)"
        }
    }
}

/// Renders modified recordings with the selected reference voice, then applies playback speed.
enum VoiceConverter {
    /// Builds the reusable, normal-speed voice conversion for one source/style/noise combination.
    static func prepareBase(
        source: URL,
        target: URL?,
        destination: URL,
        reduceNoise: Bool
    ) async throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("VoiceOver-voice-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        try Task.checkCancellation()
        let prepared = scratch.appendingPathComponent("source.wav")
        try AudioProcessor.export(source: source, destination: prepared, reduceNoise: reduceNoise)
        try Task.checkCancellation()
        if let target {
            guard manager.fileExists(atPath: target.path) else { throw VoiceConversionFailure.referenceUnavailable }
            let reference: URL
            if target.pathExtension.lowercased() == "wav" {
                reference = target
            } else {
                reference = scratch.appendingPathComponent("reference.wav")
                try AudioProcessor.export(source: target, destination: reference, reduceNoise: false)
            }
            do {
                try await runSeedVC(source: prepared, target: reference, output: destination, scratch: scratch)
            } catch {
                try? manager.removeItem(at: destination)
                throw error
            }
        } else {
            try AudioProcessor.export(source: prepared, destination: destination, reduceNoise: false)
        }
    }

    /// Applies speed to an already prepared normal-speed voice without invoking Seed-VC.
    static func render(base: URL, destination: URL, speed: VoiceSpeed) throws {
        try AudioProcessor.export(source: base, destination: destination, reduceNoise: false, speed: speed)
    }

    static func render(
        source: URL,
        target: URL?,
        destination: URL,
        reduceNoise: Bool,
        speed: VoiceSpeed
    ) async throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("VoiceOver-voice-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        let base = scratch.appendingPathComponent("base.wav")
        try await prepareBase(source: source, target: target, destination: base, reduceNoise: reduceNoise)
        try Task.checkCancellation()
        try render(base: base, destination: destination, speed: speed)
    }

    private struct Runtime {
        let root: URL
        let python: URL
    }

    private static func runtime() -> Runtime? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["VOICEOVER_SEEDVC_ROOT"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("SeedVC", isDirectory: true))
        }
        let project = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(project.appendingPathComponent("third_party/seed-vc", isDirectory: true))
        candidates.append(URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true).appendingPathComponent("third_party/seed-vc", isDirectory: true))
        for root in candidates where manager.fileExists(atPath: root.appendingPathComponent("inference.py").path) {
            let bundled = root.appendingPathComponent("venv/bin/python")
            let development = root.appendingPathComponent(".venv/bin/python")
            if manager.isExecutableFile(atPath: bundled.path) { return Runtime(root: root, python: bundled) }
            if manager.isExecutableFile(atPath: development.path) { return Runtime(root: root, python: development) }
        }
        return nil
    }

    private static func runSeedVC(source: URL, target: URL, output: URL, scratch: URL) async throws {
        guard let runtime = runtime() else { throw VoiceConversionFailure.runtimeUnavailable }
        let root = runtime.root
        let python = runtime.python
        let script = root.appendingPathComponent("inference.py")
        let log = scratch.appendingPathComponent("seed-vc.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        let state = SeedProcessState()
        let process = state.process
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = [
            script.path,
            "--source", source.path,
            "--target", target.path,
            "--output-file", output.path,
            "--diffusion-steps", "10",
            "--fp16", "False"
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        let cache = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        environment["XDG_CACHE_HOME"] = cache.path
        environment["HF_HOME"] = cache.appendingPathComponent("huggingface", isDirectory: true).path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TORCH_HOME"] = cache.appendingPathComponent("torch", isDirectory: true).path
        environment["NUMBA_CACHE_DIR"] = cache.appendingPathComponent("numba", isDirectory: true).path
        process.environment = environment

        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { terminated in
                    guard state.claimCompletion() else { return }
                    try? logHandle.close()
                    if state.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if terminated.terminationStatus == 0,
                              FileManager.default.fileExists(atPath: output.path) {
                        continuation.resume()
                    } else {
                        let detail = (try? String(contentsOf: log, encoding: .utf8))?
                            .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
                        continuation.resume(throwing: VoiceConversionFailure.conversionFailed(detail))
                    }
                }
                do {
                    if state.wasCancelled { throw CancellationError() }
                    try process.run()
                    if state.wasCancelled { state.terminate() }
                } catch {
                    guard state.claimCompletion() else { return }
                    try? logHandle.close()
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            state.cancel()
        })
        try Task.checkCancellation()
    }
}

private final class SeedProcessState: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var completed = false
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
