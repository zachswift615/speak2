import Foundation
import os

/// Protocol defining a speech-to-text transcription engine.
/// Implementations must be actors to ensure thread-safe model access.
protocol TranscriptionEngine: Actor {
    /// Whether the model is currently loaded and ready for transcription
    var isModelLoaded: Bool { get }

    /// Load the model, reporting progress via the handler
    /// - Parameter progressHandler: Called with progress from 0.0 to 1.0
    func loadModel(progressHandler: @escaping (Double) -> Void) async throws

    /// Unload the model to free memory
    func unloadModel() async

    /// Transcribe audio from the given file URL
    /// - Parameters:
    ///   - audioURL: Path to 16kHz mono PCM audio file
    ///   - dictionaryHint: Optional comma-separated list of words to prioritize during transcription
    /// - Returns: Transcribed text
    func transcribe(audioURL: URL, dictionaryHint: String?) async throws -> String
}

struct StreamingTextUpdate: Sendable {
    let confirmedText: String
    let unconfirmedText: String
}

protocol StreamingTranscriptionEngine: Actor {
    /// Start capturing microphone audio.
    /// - Parameters:
    ///   - dictionaryHint: Optional comma-separated vocabulary to bias transcription toward.
    ///   - liveUpdates: When true, run periodic transcription passes and publish them on
    ///     `streamingTextUpdates`. When false, only capture audio; the full transcription is
    ///     produced by `stopStreaming()`.
    ///   - onMicrophoneLive: Called once when the microphone is actually delivering audio
    ///     (may be on any thread).
    func startStreaming(
        dictionaryHint: String?,
        liveUpdates: Bool,
        onMicrophoneLive: (@Sendable () -> Void)?
    ) async throws
    func stopStreaming() async throws -> String  // returns final accumulated text
    var streamingTextUpdates: AsyncStream<StreamingTextUpdate> { get }
}

/// Thread-safe container for the latest streaming text, written from the streaming loop
/// and read from the engine actor when stopping.
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

// MARK: - Word-level diff helper (shared by Whisper and Parakeet streaming)

/// Word-level common-prefix diff. Words stable across consecutive transcription passes = confirmed.
/// Remainder = unconfirmed. Case-insensitive, punctuation-tolerant comparison.
func diffWords(previous: String, current: String) -> (confirmed: String, unconfirmed: String) {
    let previousWords = previous.split(separator: " ").map(String.init)
    let currentWords = current.split(separator: " ").map(String.init)

    var commonCount = 0
    let minCount = min(previousWords.count, currentWords.count)
    for i in 0..<minCount {
        if normalizeForComparison(previousWords[i]) == normalizeForComparison(currentWords[i]) {
            commonCount += 1
        } else {
            break
        }
    }

    let confirmed = currentWords.prefix(commonCount).joined(separator: " ")
    let unconfirmed = currentWords.dropFirst(commonCount).joined(separator: " ")

    return (confirmed: confirmed, unconfirmed: unconfirmed)
}

func normalizeForComparison(_ word: String) -> String {
    var s = word.lowercased()
    while let last = s.last, last.isPunctuation {
        s.removeLast()
    }
    return s
}

// MARK: - Transcription artifact stripping

/// Strip bracketed artifacts that Whisper sometimes produces (e.g., [Silence], [BLANK_AUDIO], (Music)).
func stripTranscriptionArtifacts(_ text: String) -> String {
    text.replacingOccurrences(of: "\\[.*?\\]|\\(.*?\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

enum TranscriptionEngineError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case downloadFailed(String)
    /// The recording produced no usable audio because microphone capture failed.
    case noAudioCaptured(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded"
        case .noAudioCaptured(let reason):
            return "No audio was captured: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        }
    }
}
