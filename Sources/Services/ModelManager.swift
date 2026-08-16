import Foundation

/// Manages transcription model lifecycle: downloading, loading, switching, and deletion.
@MainActor
class ModelManager: ObservableObject {
    private var whisperTranscriber: WhisperTranscriber?
    private var parakeetTranscriber: ParakeetTranscriber?

    private let appState = AppState.shared

    /// The currently active transcription engine (if any model is loaded)
    var currentEngine: (any TranscriptionEngine)? {
        switch appState.currentlyLoadedModel {
        case .whisperTinyEn, .whisperBaseEn, .whisperSmallEn, .whisperLargeV3, .whisperLargeV3Turbo:
            return whisperTranscriber
        case .parakeetV3:
            return parakeetTranscriber
        case nil:
            return nil
        }
    }

    /// The currently active streaming engine (if any model is loaded)
    private var currentStreamingEngine: (any StreamingTranscriptionEngine)? {
        switch appState.currentlyLoadedModel {
        case .whisperTinyEn, .whisperBaseEn, .whisperSmallEn, .whisperLargeV3, .whisperLargeV3Turbo:
            return whisperTranscriber
        case .parakeetV3:
            return parakeetTranscriber
        case nil:
            return nil
        }
    }

    /// Load the specified model, unloading any currently loaded model first
    func loadModel(_ model: TranscriptionModel, progressHandler: @escaping (Double) -> Void) async throws {
        // Unload current model if different
        if let current = appState.currentlyLoadedModel, current != model {
            await unloadCurrentModel()
        }

        // Skip if already loaded
        if appState.currentlyLoadedModel == model {
            progressHandler(1.0)
            return
        }

        appState.isModelLoaded = false
        appState.modelDownloadProgress = 0.0
        appState.recordingState = .loadingModel

        switch model {
        case .whisperTinyEn, .whisperBaseEn, .whisperSmallEn, .whisperLargeV3, .whisperLargeV3Turbo:
            let variant = model.whisperVariant!
            let transcriber = WhisperTranscriber()
            let modelFolder = try await transcriber.loadModel(variant: variant) { progress in
                Task { @MainActor in
                    self.appState.modelDownloadProgress = progress
                    progressHandler(progress)
                }
            }
            TranscriptionModel.setStoredWhisperPath(modelFolder, for: model)
            whisperTranscriber = transcriber

        case .parakeetV3:
            let transcriber = ParakeetTranscriber()
            try await transcriber.loadModel { progress in
                Task { @MainActor in
                    self.appState.modelDownloadProgress = progress
                    progressHandler(progress)
                }
            }
            parakeetTranscriber = transcriber
        }

        appState.currentlyLoadedModel = model
        appState.selectedModel = model
        TranscriptionModel.saved = model
        appState.isModelLoaded = true
        appState.recordingState = .idle
        appState.refreshDownloadedModels()
    }

    /// Unload the currently loaded model to free memory
    func unloadCurrentModel() async {
        if let whisper = whisperTranscriber {
            await whisper.unloadModel()
            whisperTranscriber = nil
        }
        if let parakeet = parakeetTranscriber {
            await parakeet.unloadModel()
            parakeetTranscriber = nil
        }
        appState.currentlyLoadedModel = nil
        appState.isModelLoaded = false
    }

    /// Delete a model's files from disk
    func deleteModel(_ model: TranscriptionModel) async throws {
        // Unload if this is the current model
        if appState.currentlyLoadedModel == model {
            await unloadCurrentModel()
        }

        let path = model.storagePath
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }

        // Clear persisted Whisper path so isDownloaded and storagePath reflect deletion
        if model.whisperVariant != nil {
            TranscriptionModel.setStoredWhisperPath(nil, for: model)
        }

        appState.refreshDownloadedModels()
    }

    /// Whether the currently loaded model supports streaming transcription
    var supportsStreaming: Bool {
        currentStreamingEngine != nil
    }

    /// The current engine's streaming text updates, or nil if no streaming engine is loaded
    var streamingTextUpdates: AsyncStream<StreamingTextUpdate>? {
        get async {
            guard let engine = currentStreamingEngine else { return nil }
            return await engine.streamingTextUpdates
        }
    }

    /// Start streaming transcription using the currently loaded engine.
    /// - Parameter liveUpdates: whether to publish intermediate text on `streamingTextUpdates`.
    func startStreaming(
        dictionaryHint: String? = nil,
        liveUpdates: Bool,
        onMicrophoneLive: (@Sendable () -> Void)? = nil
    ) async throws {
        guard let engine = currentStreamingEngine else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        try await engine.startStreaming(
            dictionaryHint: dictionaryHint,
            liveUpdates: liveUpdates,
            onMicrophoneLive: onMicrophoneLive
        )
    }

    /// Stop streaming transcription and return the final accumulated text
    func stopStreaming() async throws -> String {
        guard let engine = currentStreamingEngine else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.stopStreaming()
    }

    /// Transcribe audio using the currently loaded model
    /// - Parameters:
    ///   - audioURL: Path to the audio file
    ///   - dictionaryHint: Optional comma-separated list of words to prioritize
    /// - Returns: Transcribed text
    func transcribe(audioURL: URL, dictionaryHint: String? = nil) async throws -> String {
        guard let engine = currentEngine else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.transcribe(audioURL: audioURL, dictionaryHint: dictionaryHint)
    }
}
