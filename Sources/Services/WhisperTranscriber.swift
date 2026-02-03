import Foundation
import WhisperKit

actor WhisperTranscriber: TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var isLoading = false

    private static let modelVariant = "base.en"

    var isModelLoaded: Bool {
        whisperKit != nil
    }

    func loadModel(progressHandler: @escaping (Double) -> Void) async throws {
        guard !isLoading && whisperKit == nil else { return }
        isLoading = true

        defer { isLoading = false }

        // Download model first with progress tracking
        let modelFolder = try await WhisperKit.download(
            variant: Self.modelVariant,
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
    }

    func unloadModel() async {
        whisperKit = nil
    }

    func transcribe(audioURL: URL, dictionaryHint: String? = nil) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        var results: [TranscriptionResult]

        // Try with vocabulary hint first if provided
        if let hint = dictionaryHint, !hint.isEmpty {
            var decodeOptions = DecodingOptions()
            decodeOptions.promptTokens = whisperKit.tokenizer?.encode(text: hint)

            results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: decodeOptions
            )

            // Fallback: if promptTokens caused empty results, retry without
            if results.isEmpty || results.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                results = try await whisperKit.transcribe(audioPath: audioURL.path)
            }
        } else {
            results = try await whisperKit.transcribe(audioPath: audioURL.path)
        }

        let transcription = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return transcription
    }
}
