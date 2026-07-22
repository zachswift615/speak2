import Accelerate
import AVFoundation
import Foundation
import os
import WhisperKit

private func whisperLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[WhisperStream] \(message())")
    #endif
}

/// Races `operation` against a timeout so a stalled network call (e.g. WhisperKit fetching its
/// tokenizer from Hugging Face) fails with a clear error instead of hanging indefinitely.
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranscriptionEngineError.downloadFailed(
                "Timed out after \(Int(seconds))s waiting for the model to load — check your network connection and try again."
            )
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TranscriptionEngineError.downloadFailed("Model loading was cancelled.")
        }
        return result
    }
}

/// Thread-safe container for the latest streaming text, written from the streaming loop
/// and read from the WhisperTranscriber actor when stopping.
final class StreamingTextSnapshot: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _confirmed: String = ""
    private var _unconfirmed: String = ""

    func update(confirmed: String, unconfirmed: String) {
        os_unfair_lock_lock(&lock)
        _confirmed = confirmed
        _unconfirmed = unconfirmed
        os_unfair_lock_unlock(&lock)
    }

    func read() -> (confirmed: String, unconfirmed: String) {
        os_unfair_lock_lock(&lock)
        let result = (_confirmed, _unconfirmed)
        os_unfair_lock_unlock(&lock)
        return result
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        _confirmed = ""
        _unconfirmed = ""
        os_unfair_lock_unlock(&lock)
    }
}

/// Thread-safe `[Float]` accumulator for audio samples using `os_unfair_lock`.
final class AudioSampleBuffer: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _samples: [Float] = []

    func append(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        _samples.append(contentsOf: samples)
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [Float] {
        os_unfair_lock_lock(&lock)
        let copy = _samples
        os_unfair_lock_unlock(&lock)
        return copy
    }

    var count: Int {
        os_unfair_lock_lock(&lock)
        let c = _samples.count
        os_unfair_lock_unlock(&lock)
        return c
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        _samples.removeAll()
        os_unfair_lock_unlock(&lock)
    }
}

actor WhisperTranscriber: TranscriptionEngine, StreamingTranscriptionEngine {
    /// Minimum audio samples before attempting transcription (0.3s at 16kHz)
    private let minTranscriptionSamples = 4800
    /// Maximum samples to send per streaming pass (5s at 16kHz)
    private let maxStreamingSamples = 80000

    private var whisperKit: WhisperKit?
    private var isLoading = false
    /// True when the loaded model supports multiple languages (e.g. large-v3).
    /// When true, DecodingOptions.detectLanguage is set so Whisper transcribes
    /// in the spoken language instead of defaulting to English.
    private var isMultilingual = false

    // MARK: - Streaming properties
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AudioSampleBuffer?
    private var activeDecodeOptions: DecodingOptions?
    private var streamingTask: Task<Void, Error>?
    private var _streamingTextUpdates: AsyncStream<StreamingTextUpdate>?
    private var streamContinuation: AsyncStream<StreamingTextUpdate>.Continuation?
    private let latestStreamingText = StreamingTextSnapshot()

    var isModelLoaded: Bool {
        whisperKit != nil
    }

    /// Apply the user's language preference to decode options (multilingual models only).
    /// A specific selected language is forced; otherwise fall back to auto-detection.
    /// Reads UserDefaults fresh each call so changes take effect on the next dictation
    /// without reloading the model.
    private func applyLanguagePreference(to options: inout DecodingOptions) {
        guard isMultilingual else { return }
        if let code = TranscriptionLanguagePreference.savedCode {
            options.language = code
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }
    }

    /// Load a Whisper model by variant string (e.g. "base.en", "small.en", "large-v3").
    /// - Parameter existingModelFolder: A previously-downloaded model folder to load from directly,
    ///   skipping the Hugging Face Hub lookup entirely. Pass this whenever the model is already
    ///   known to be on disk (e.g. re-selecting a downloaded model) so loading never depends on
    ///   network availability — WhisperKit.download() always performs a live Hub API round-trip
    ///   to list/verify remote files, even when nothing needs to be downloaded, and will hang
    ///   indefinitely (no timeout) if that request stalls.
    /// - Returns: The model folder URL so the caller can persist it for isDownloaded/delete.
    func loadModel(
        variant: String,
        existingModelFolder: URL? = nil,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !isLoading && whisperKit == nil else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        isLoading = true

        defer { isLoading = false }

        let modelFolder: URL
        if let existingModelFolder, FileManager.default.fileExists(atPath: existingModelFolder.path) {
            modelFolder = existingModelFolder
            progressHandler(1.0)
        } else {
            // Download model first with progress tracking
            modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: await AppState.modelStorageLocation,
                progressCallback: { progress in
                    Task { @MainActor in
                        progressHandler(progress.fractionCompleted)
                    }
                }
            )
        }

        // Initialize WhisperKit with the downloaded model (no re-download needed).
        // The first time a given variant loads, this involves a genuinely slow step: macOS
        // compiles the CoreML model for the Neural Engine on-device, which can take several
        // minutes for larger models (confirmed via sampling: CPU-bound work in the `aned`
        // daemon, not a hang). WhisperKit also fetches its tokenizer from a separate Hub repo
        // here since it isn't bundled with the CoreML model, which needs network the first time.
        // Guard with a generous timeout as a safety net for a genuinely stalled request, without
        // cutting off a slow-but-legitimate first-time compile.
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )

        whisperKit = try await withTimeout(seconds: 600) {
            try await WhisperKit(config)
        }
        isMultilingual = !variant.contains(".en")
        return modelFolder
    }

    // MARK: - TranscriptionEngine (protocol)

    /// Protocol conformance; uses default variant. Prefer loadModel(variant:progressHandler:) for multi-variant use.
    func loadModel(progressHandler: @escaping (Double) -> Void) async throws {
        _ = try await loadModel(variant: "base.en", progressHandler: progressHandler)
    }

    func unloadModel() async {
        // Clean up audio engine if running
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioBuffer = nil
        activeDecodeOptions = nil

        streamingTask?.cancel()
        let pendingTask = streamingTask
        streamingTask = nil
        // Await to avoid racing a concurrent transcription against model teardown
        _ = try? await pendingTask?.value
        streamContinuation?.finish()
        streamContinuation = nil
        _streamingTextUpdates = nil

        whisperKit = nil
    }

    func transcribe(audioURL: URL, dictionaryHint: String? = nil) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        var results: [TranscriptionResult]

        // Build decode options — force or auto-detect language for multilingual models
        var decodeOptions = DecodingOptions()
        applyLanguagePreference(to: &decodeOptions)

        // Try with vocabulary hint first if provided
        if let hint = dictionaryHint, !hint.isEmpty {
            decodeOptions.promptTokens = whisperKit.tokenizer?.encode(text: hint)

            results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: decodeOptions
            )

            // Fallback: if promptTokens caused empty results, retry without
            if results.isEmpty || results.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                var fallbackOptions = DecodingOptions()
                applyLanguagePreference(to: &fallbackOptions)
                results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: fallbackOptions)
            }
        } else {
            results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        }

        let transcription = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return transcription
    }

    // MARK: - StreamingTranscriptionEngine

    var streamingTextUpdates: AsyncStream<StreamingTextUpdate> {
        if let stream = _streamingTextUpdates {
            return stream
        }
        // Return an empty finished stream if not streaming
        return AsyncStream { $0.finish() }
    }

    func startStreaming(dictionaryHint: String?) async throws {
        guard let whisperKit = whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        // Build decode options — force or auto-detect language for multilingual models
        var decodeOptions = DecodingOptions()
        decodeOptions.skipSpecialTokens = true
        applyLanguagePreference(to: &decodeOptions)
        if let hint = dictionaryHint, !hint.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            decodeOptions.promptTokens = tokenizer.encode(text: hint)
        }
        activeDecodeOptions = decodeOptions
        latestStreamingText.reset()

        // Create AsyncStream + continuation
        let (stream, continuation) = AsyncStream<StreamingTextUpdate>.makeStream()
        _streamingTextUpdates = stream
        streamContinuation = continuation

        // Set up AudioSampleBuffer
        let buffer = AudioSampleBuffer()
        audioBuffer = buffer

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionEngineError.transcriptionFailed("Failed to create 16kHz mono format")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw TranscriptionEngineError.transcriptionFailed("Failed to create audio converter")
        }

        whisperLog("Hardware format: \(hardwareFormat)")

        // Sample counter for periodic RMS/peak logging (~1 second intervals)
        var samplesSinceLastLog: Int = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { tapBuffer, _ in
            let frameCount = AVAudioFrameCount(
                targetFormat.sampleRate * Double(tapBuffer.frameLength) / tapBuffer.format.sampleRate
            )
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return tapBuffer
            }

            guard status != .error, error == nil else { return }

            // Extract Float array from channel data
            guard let channelData = outputBuffer.floatChannelData else { return }
            let length = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: length))

            buffer.append(samples)

            // Log RMS/peak every ~1 second
            samplesSinceLastLog += length
            if samplesSinceLastLog >= 16000 {
                samples.withUnsafeBufferPointer { ptr in
                    var rms: Float = 0
                    var peak: Float = 0
                    vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(ptr.count))
                    vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(ptr.count))
                    whisperLog("Audio level — RMS: \(rms), Peak: \(peak), Total samples: \(buffer.count)")
                }
                samplesSinceLastLog = 0
            }
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            whisperLog("Error starting audio engine: \(error)")
            continuation.finish()
            streamContinuation = nil
            _streamingTextUpdates = nil
            audioEngine = nil
            audioBuffer = nil
            activeDecodeOptions = nil
            throw TranscriptionEngineError.transcriptionFailed("Audio engine failed to start: \(error.localizedDescription)")
        }

        // Launch streaming transcription loop
        let snapshot = latestStreamingText
        let capturedWhisperKit = whisperKit
        let capturedMinSamples = minTranscriptionSamples
        let capturedMaxSamples = maxStreamingSamples

        // Build lightweight decode options for streaming passes.
        // promptTokens cause empty results with audioArray, so only set language options.
        var streamingDecodeOptions: DecodingOptions?
        if isMultilingual {
            var opts = DecodingOptions()
            opts.skipSpecialTokens = true
            applyLanguagePreference(to: &opts)
            streamingDecodeOptions = opts
        }

        streamingTask = Task {
            var previousText = ""

            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                let allSamples = buffer.snapshot()

                guard allSamples.count >= capturedMinSamples else { continue }

                // Cap at ~5 seconds to keep each pass fast.
                // For longer recordings, transcribe only the recent window;
                // the final file-based transcription captures everything.
                let samples = allSamples.count > capturedMaxSamples
                    ? Array(allSamples.suffix(capturedMaxSamples))
                    : allSamples

                do {
                    let startTime = CFAbsoluteTimeGetCurrent()
                    let results: [TranscriptionResult]
                    if let opts = streamingDecodeOptions {
                        results = try await capturedWhisperKit.transcribe(
                            audioArray: samples,
                            decodeOptions: opts
                        )
                    } else {
                        results = try await capturedWhisperKit.transcribe(
                            audioArray: samples
                        )
                    }
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

                    let currentText = results
                        .compactMap { $0.text }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    whisperLog("pass: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s audio) → \(String(format: "%.1f", elapsed))s → '\(currentText)'")

                    // Skip empty results to avoid flickering the overlay back to "Listening..."
                    guard !currentText.isEmpty else { continue }

                    let diff = diffWords(previous: previousText, current: currentText)
                    previousText = currentText

                    snapshot.update(confirmed: diff.confirmed, unconfirmed: diff.unconfirmed)
                    continuation.yield(StreamingTextUpdate(
                        confirmedText: diff.confirmed,
                        unconfirmedText: diff.unconfirmed
                    ))
                } catch {
                    // Log but continue — transient transcription errors shouldn't kill the loop
                    whisperLog("Transcription error: \(error)")
                }
            }
        }
    }

    // MARK: - Stop Streaming

    /// Write Float32 samples to a temporary 16kHz mono WAV file for reliable transcription.
    private func writeSamplesToTempFile(_ samples: [Float]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("whisper_stream_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionEngineError.transcriptionFailed("Failed to create audio format")
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriptionEngineError.transcriptionFailed("Failed to create PCM buffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(pcmBuffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try audioFile.write(from: pcmBuffer)

        return fileURL
    }

    func stopStreaming() async throws -> String {
        // 1. Stop audio engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        // 2. Cancel streaming loop task and AWAIT completion to avoid racing
        // a concurrent whisperKit.transcribe() call against the final one below
        streamingTask?.cancel()
        let task = streamingTask
        streamingTask = nil
        try? await task?.value

        // 3. Final transcription — write buffer to temp file and use the proven
        // transcribe(audioPath:) API (transcribe(audioArray:) is unreliable)
        var finalText = ""

        if let buffer = audioBuffer, let whisperKit = whisperKit {
            let samples = buffer.snapshot()
            whisperLog("stopStreaming: buffer has \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")
            if samples.count >= minTranscriptionSamples {
                do {
                    let tempFile = try writeSamplesToTempFile(samples)
                    defer { try? FileManager.default.removeItem(at: tempFile) }

                    // Try with decode options (dictionary hint) first
                    var results = try await whisperKit.transcribe(
                        audioPath: tempFile.path,
                        decodeOptions: activeDecodeOptions ?? DecodingOptions()
                    )

                    finalText = results
                        .compactMap { $0.text }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // Fallback: if promptTokens caused empty results, retry without
                    if finalText.isEmpty {
                        whisperLog("stopStreaming: retrying without decodeOptions")
                        results = try await whisperKit.transcribe(audioPath: tempFile.path)
                        finalText = results
                            .compactMap { $0.text }
                            .joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    whisperLog("stopStreaming: final transcription = '\(finalText)'")
                } catch {
                    whisperLog("Final transcription error: \(error)")
                }
            }
        } else {
            whisperLog("stopStreaming: buffer or whisperKit is nil")
        }

        // 4. Fallback: if final transcription failed or empty, use latest snapshot
        if finalText.isEmpty {
            let (confirmed, unconfirmed) = latestStreamingText.read()
            whisperLog("stopStreaming: final empty, falling back to snapshot: confirmed='\(confirmed)' unconfirmed='\(unconfirmed)'")
            finalText = [confirmed, unconfirmed]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        whisperLog("stopStreaming: returning '\(finalText)'")

        // 5. Clean up all state
        streamContinuation?.finish()
        streamContinuation = nil
        _streamingTextUpdates = nil
        audioBuffer?.reset()
        audioBuffer = nil
        activeDecodeOptions = nil

        return finalText
    }
}
