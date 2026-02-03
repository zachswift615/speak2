import Foundation

@MainActor
class DictationController {
    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let textInjector = TextInjector()
    private let dictionaryProcessor = DictionaryProcessor()
    private let appState = AppState.shared

    let modelManager = ModelManager()

    private var currentRecordingURL: URL?

    func updateHotkey(_ option: HotkeyOption) {
        hotkeyManager.updateHotkey(option)
    }

    /// Load the selected model (or specified model)
    func loadModel(_ model: TranscriptionModel? = nil) async throws {
        let targetModel = model ?? appState.selectedModel
        try await modelManager.loadModel(targetModel) { [weak self] progress in
            Task { @MainActor in
                self?.appState.modelDownloadProgress = progress
            }
        }
    }

    func start() async throws {
        // Load model if not already loaded
        if !appState.isModelLoaded {
            try await loadModel()
        }

        // Start hotkey monitoring
        guard hotkeyManager.start() else {
            throw DictationError.accessibilityDenied
        }

        hotkeyManager.onKeyDown = { [weak self] in
            self?.startRecording()
        }

        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }
    }

    private func startRecording() {
        guard appState.recordingState == .idle else { return }

        do {
            currentRecordingURL = try audioRecorder.startRecording()
            appState.recordingState = .recording
        } catch {
            appState.lastError = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() {
        guard appState.recordingState == .recording else { return }

        guard let audioURL = audioRecorder.stopRecording() else {
            appState.recordingState = .idle
            return
        }

        appState.recordingState = .transcribing

        Task {
            do {
                // Use the user's selected language for dictionary processing
                let selectedLanguage = appState.dictionaryState.selectedLanguage

                // Get dictionary hint for model prompting (mainly for WhisperKit)
                let dictionaryHint = appState.dictionaryState.promptText(for: selectedLanguage)

                // Transcribe with dictionary hint
                var text = try await modelManager.transcribe(
                    audioURL: audioURL,
                    dictionaryHint: dictionaryHint.isEmpty ? nil : dictionaryHint
                )

                // Post-process with dictionary entries (applies to all engines)
                let entries = appState.dictionaryState.enabledEntries(for: selectedLanguage)
                if !entries.isEmpty {
                    text = dictionaryProcessor.process(text, using: entries, language: selectedLanguage)
                }

                await MainActor.run {
                    if !text.isEmpty {
                        textInjector.inject(text: text)
                    }
                    appState.recordingState = .idle
                }
            } catch {
                await MainActor.run {
                    appState.lastError = "Transcription failed: \(error.localizedDescription)"
                    appState.recordingState = .idle
                }
            }

            audioRecorder.cleanup()
        }
    }

    func stop() {
        hotkeyManager.stop()
        if audioRecorder.isRecording {
            _ = audioRecorder.stopRecording()
        }
        audioRecorder.cleanup()
    }
}

enum DictationError: Error {
    case accessibilityDenied
    case microphoneDenied
    case modelNotLoaded
}
