import AVFoundation
import Foundation
import os

/// Thread-safe `[Float]` accumulator for audio samples using `os_unfair_lock`.
/// Appended from the audio tap thread, snapshotted from transcription tasks.
final class AudioSampleBuffer: @unchecked Sendable {
    fileprivate var lock = os_unfair_lock()
    fileprivate var _samples: [Float] = []

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

extension AudioSampleBuffer {
    /// Copy of the last `maxCount` samples (or all of them if fewer). Only the tail is copied under
    /// the lock, so periodic live-transcription passes stay cheap on long recordings.
    func suffix(_ maxCount: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        let copy = Array(_samples.suffix(maxCount))
        os_unfair_lock_unlock(&lock)
        return copy
    }
}

/// Write 16 kHz mono Float32 samples to a temporary WAV file (the format `AudioResampler` produces),
/// for engines whose most reliable transcription API takes a file path. Caller deletes the file.
func writeSamplesToTempWAV(_ samples: [Float], filenamePrefix: String) throws -> URL {
    let format = AudioResampler.targetFormat
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(filenamePrefix)_\(UUID().uuidString).wav")

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let channelData = pcmBuffer.floatChannelData else {
        throw TranscriptionEngineError.transcriptionFailed("Failed to create PCM buffer")
    }
    pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        if let base = source.baseAddress {
            channelData[0].update(from: base, count: samples.count)
        }
    }

    let audioFile = try AVAudioFile(
        forWriting: fileURL,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try audioFile.write(from: pcmBuffer)
    return fileURL
}
