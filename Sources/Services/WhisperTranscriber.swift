import AVFoundation
import Foundation
import WhisperKit

private func whisperLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[WhisperStream] \(message())")
    #endif
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
    private let capture: AudioCaptureService
    private var captureToken: AudioCaptureToken?
    private var audioBuffer: AudioSampleBuffer?
    private var activeDictionaryHint: String?
    private var streamingTask: Task<Void, Error>?
    private var _streamingTextUpdates: AsyncStream<StreamingTextUpdate>?
    private var streamContinuation: AsyncStream<StreamingTextUpdate>.Continuation?
    private let latestStreamingText = StreamingTextSnapshot()

    var isModelLoaded: Bool {
        whisperKit != nil
    }

    init(capture: AudioCaptureService = .shared) {
        self.capture = capture
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
    /// Returns the model folder URL so the caller can persist it for isDownloaded/delete.
    func loadModel(variant: String, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        guard !isLoading && whisperKit == nil else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        isLoading = true

        defer { isLoading = false }

        // Download model first with progress tracking
        let modelFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: await AppState.modelStorageLocation,
            progressCallback: { progress in
                Task { @MainActor in
                    progressHandler(progress.fractionCompleted)
                }
            }
        )

        // Initialize WhisperKit with the downloaded model (no re-download needed)
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )

        whisperKit = try await WhisperKit(config)
        isMultilingual = !variant.contains(".en")
        return modelFolder
    }

    // MARK: - TranscriptionEngine (protocol)

    /// Protocol conformance; uses default variant. Prefer loadModel(variant:progressHandler:) for multi-variant use.
    func loadModel(progressHandler: @escaping (Double) -> Void) async throws {
        _ = try await loadModel(variant: "base.en", progressHandler: progressHandler)
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
        // Await to avoid racing a concurrent transcription against model teardown
        _ = try? await pendingTask?.value
        resetStreamingState()

        whisperKit = nil
    }

    func transcribe(audioURL: URL, dictionaryHint: String? = nil) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        var results: [TranscriptionResult]

        // Build decode options — force or auto-detect language for multilingual models
        var decodeOptions = DecodingOptions()
        decodeOptions.skipSpecialTokens = true
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
                fallbackOptions.skipSpecialTokens = true
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

    func startStreaming(
        dictionaryHint: String?,
        liveUpdates: Bool,
        onMicrophoneLive: (@Sendable () -> Void)?
    ) async throws {
        guard let whisperKit = whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        activeDictionaryHint = dictionaryHint
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
            whisperLog("startStreaming: superseded before capture started")
            return
        } catch {
            whisperLog("Error starting audio capture: \(error)")
            resetStreamingState()
            throw error
        }

        // stopStreaming() may have run while we were awaiting capture start; the capture we just
        // started belongs to nobody, so release it (the token makes this safe against newer sessions).
        guard audioBuffer === buffer else {
            whisperLog("startStreaming: stopped before capture started — tearing down")
            await capture.stop(token)
            return
        }
        captureToken = token

        // Without live updates there is nothing to show; the final transcription happens in stopStreaming.
        guard liveUpdates else { return }

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

                // Transcribe only the most recent ~5 s window to keep each pass fast;
                // the final pass in stopStreaming covers the whole recording.
                let samples = buffer.suffix(capturedMaxSamples)
                guard samples.count >= capturedMinSamples else { continue }

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

    /// Stop capture, transcribe the whole recording, and return the text.
    /// Throws if capture failed and nothing usable was recorded, or if the final transcription fails
    /// and there is no live-transcription text to fall back on.
    func stopStreaming() async throws -> String {
        // 1. Stop microphone capture
        var captureReport: AudioCaptureSessionReport?
        if let token = captureToken {
            captureReport = await capture.stop(token)
        }
        captureToken = nil

        // 2. Cancel streaming loop task and AWAIT completion to avoid racing
        // a concurrent whisperKit.transcribe() call against the final one below
        streamingTask?.cancel()
        let task = streamingTask
        streamingTask = nil
        try? await task?.value

        let buffer = audioBuffer
        let dictionaryHint = activeDictionaryHint
        resetStreamingState()

        // 3. Final transcription over the entire recording via the file-based API
        // (transcribe(audioArray:) is unreliable with prompt tokens).
        let samples = buffer?.snapshot() ?? []
        whisperLog("stopStreaming: buffer has \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

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

        DebugRecordingStore.saveIfEnabled(samples, engine: "whisper")

        do {
            let tempFile = try writeSamplesToTempWAV(samples, filenamePrefix: "whisper_stream")
            defer { try? FileManager.default.removeItem(at: tempFile) }
            let finalText = try await transcribe(audioURL: tempFile, dictionaryHint: dictionaryHint)
            whisperLog("stopStreaming: final transcription = '\(finalText)'")
            if !finalText.isEmpty { return finalText }
        } catch {
            whisperLog("Final transcription error: \(error)")
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
        activeDictionaryHint = nil
    }
}
