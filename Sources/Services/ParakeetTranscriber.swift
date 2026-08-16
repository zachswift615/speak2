import AVFoundation
import Foundation
import FluidAudio

private func parakeetLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[ParakeetStream] \(message())")
    #endif
}

actor ParakeetTranscriber: TranscriptionEngine, StreamingTranscriptionEngine {
    /// Minimum audio samples before attempting transcription (0.3s at 16kHz)
    private let minTranscriptionSamples = 4800
    /// Maximum samples to send per streaming pass (5s at 16kHz)
    private let maxStreamingSamples = 80000

    private var asrManager: AsrManager?
    private var loadedModels: AsrModels?
    private var isLoading = false

    // MARK: - Streaming properties
    private let capture: AudioCaptureService
    private var captureToken: AudioCaptureToken?
    private var audioBuffer: AudioSampleBuffer?
    private var streamingTask: Task<Void, Error>?
    private var _streamingTextUpdates: AsyncStream<StreamingTextUpdate>?
    private var streamContinuation: AsyncStream<StreamingTextUpdate>.Continuation?
    private let latestStreamingText = StreamingTextSnapshot()

    var isModelLoaded: Bool {
        asrManager != nil
    }

    init(capture: AudioCaptureService = .shared) {
        self.capture = capture
    }

    func loadModel(progressHandler: @escaping (Double) -> Void) async throws {
        guard !isLoading && asrManager == nil else { return }
        isLoading = true

        defer { isLoading = false }

        // Download models with progress tracking
        // FluidAudio doesn't provide granular progress, so we estimate
        Task { @MainActor in
            progressHandler(0.1)
        }

        let models = try await AsrModels.downloadAndLoad(version: .v3)

        Task { @MainActor in
            progressHandler(0.8)
        }

        // Store models for reuse in streaming
        loadedModels = models

        // Initialize ASR manager
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)

        asrManager = manager

        Task { @MainActor in
            progressHandler(1.0)
        }
    }

    func unloadModel() async {
        // Stop microphone capture if this engine still has a streaming session open
        if let token = captureToken {
            await capture.stop(token)
            captureToken = nil
        }

        streamingTask?.cancel()
        let pendingTask = streamingTask
        streamingTask = nil
        _ = try? await pendingTask?.value
        resetStreamingState()

        asrManager = nil
        loadedModels = nil
    }

    func transcribe(audioURL: URL, dictionaryHint: String? = nil) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        // FluidAudio does not support vocabulary biasing
        // Dictionary processing will be handled post-transcription by DictionaryProcessor

        // FluidAudio expects 16kHz mono PCM samples
        let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
        let result = try await asrManager.transcribe(samples)

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - StreamingTranscriptionEngine

    var streamingTextUpdates: AsyncStream<StreamingTextUpdate> {
        if let stream = _streamingTextUpdates {
            return stream
        }
        // Return an empty finished stream if not streaming
        return AsyncStream { $0.finish() }
    }

    func startStreaming(
        dictionaryHint: String?,
        liveUpdates: Bool,
        onMicrophoneLive: (@Sendable () -> Void)?
    ) async throws {
        guard let asrManager = asrManager else {
            parakeetLog("startStreaming: model not loaded, throwing")
            throw TranscriptionEngineError.modelNotLoaded
        }

        parakeetLog("startStreaming called")
        latestStreamingText.reset()

        // Create AsyncStream + continuation
        let (stream, continuation) = AsyncStream<StreamingTextUpdate>.makeStream()
        _streamingTextUpdates = stream
        streamContinuation = continuation

        // Capture microphone audio (16 kHz mono) into the sample buffer.
        // AudioCaptureService owns the AVAudioEngine and handles device/format changes.
        let buffer = AudioSampleBuffer()
        audioBuffer = buffer

        let token: AudioCaptureToken
        do {
            token = try await capture.start(
                onSamples: { samples in buffer.append(samples) },
                onMicrophoneLive: onMicrophoneLive
            )
        } catch AudioCaptureError.superseded {
            // stopStreaming() ran before the microphone finished starting (a very quick key tap).
            // It already cleaned up; there is nothing to report.
            parakeetLog("startStreaming: superseded before capture started")
            return
        } catch {
            parakeetLog("Error starting audio capture: \(error)")
            resetStreamingState()
            throw error
        }

        // stopStreaming() may have run while we were awaiting capture start; the capture we just
        // started belongs to nobody, so release it (the token makes this safe against newer sessions).
        guard audioBuffer === buffer else {
            parakeetLog("startStreaming: stopped before capture started — tearing down")
            await capture.stop(token)
            return
        }
        captureToken = token

        // Without live updates there is nothing to show; the final transcription happens in stopStreaming.
        guard liveUpdates else { return }

        // Launch streaming transcription loop
        let snapshot = latestStreamingText
        let capturedAsrManager = asrManager
        let capturedMinSamples = minTranscriptionSamples
        let capturedMaxSamples = maxStreamingSamples

        streamingTask = Task {
            var previousText = ""

            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                // Transcribe only the most recent ~5 s window to keep each pass fast;
                // the final pass in stopStreaming covers the whole recording.
                let samples = buffer.suffix(capturedMaxSamples)
                guard samples.count >= capturedMinSamples else { continue }

                do {
                    let startTime = CFAbsoluteTimeGetCurrent()
                    let result = try await capturedAsrManager.transcribe(samples)
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

                    let currentText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    parakeetLog("pass: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s audio) → \(String(format: "%.1f", elapsed))s → '\(currentText)'")

                    // Skip empty results to avoid flickering the overlay
                    guard !currentText.isEmpty else { continue }

                    let diff = diffWords(previous: previousText, current: currentText)
                    previousText = currentText

                    snapshot.update(confirmed: diff.confirmed, unconfirmed: diff.unconfirmed)
                    continuation.yield(StreamingTextUpdate(
                        confirmedText: diff.confirmed,
                        unconfirmedText: diff.unconfirmed
                    ))
                } catch {
                    parakeetLog("Transcription error: \(error)")
                }
            }
        }
    }

    // MARK: - Stop Streaming

    /// Stop capture, transcribe the whole recording, and return the text.
    /// Throws if capture failed and nothing usable was recorded, or if the final transcription fails
    /// and there is no live-transcription text to fall back on.
    func stopStreaming() async throws -> String {
        parakeetLog("stopStreaming called")

        // 1. Stop microphone capture
        var captureReport: AudioCaptureSessionReport?
        if let token = captureToken {
            captureReport = await capture.stop(token)
        }
        captureToken = nil

        // 2. Cancel streaming loop and await completion to avoid racing
        streamingTask?.cancel()
        let task = streamingTask
        streamingTask = nil
        try? await task?.value

        let buffer = audioBuffer
        resetStreamingState()

        // 3. Final transcription over the entire recording via the file-based API
        let samples = buffer?.snapshot() ?? []
        parakeetLog("stopStreaming: buffer has \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        guard samples.count >= minTranscriptionSamples else {
            if let failure = captureReport?.failure {
                throw TranscriptionEngineError.noAudioCaptured(failure.localizedDescription)
            }
            return ""   // a tap too short to contain speech
        }

        // A device that delivered nothing but digital zeros (e.g. a virtual input, or a headset whose
        // mic never came up) is a configuration problem the user needs to hear about, not silence to
        // transcribe.
        if let report = captureReport, !report.heardAudio {
            throw TranscriptionEngineError.noAudioCaptured(
                "'\(report.inputDeviceName)' delivered only silence. Choose a different microphone in Settings → General → Microphone."
            )
        }

        DebugRecordingStore.saveIfEnabled(samples, engine: "parakeet")

        do {
            let tempFile = try writeSamplesToTempWAV(samples, filenamePrefix: "parakeet_stream")
            defer { try? FileManager.default.removeItem(at: tempFile) }
            let finalText = try await transcribe(audioURL: tempFile, dictionaryHint: nil)
            parakeetLog("stopStreaming: final transcription = '\(finalText)'")
            if !finalText.isEmpty { return finalText }
        } catch {
            parakeetLog("Final transcription error: \(error)")
            let fallback = fallbackTextFromLivePasses()
            if !fallback.isEmpty { return fallback }
            throw error
        }

        // 4. Empty final result: fall back to whatever the live passes produced
        return fallbackTextFromLivePasses()
    }

    private func fallbackTextFromLivePasses() -> String {
        let (confirmed, unconfirmed) = latestStreamingText.read()
        return [confirmed, unconfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetStreamingState() {
        streamContinuation?.finish()
        streamContinuation = nil
        _streamingTextUpdates = nil
        audioBuffer = nil
    }
}
