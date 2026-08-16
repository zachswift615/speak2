import AVFoundation
import Foundation

/// Converts PCM buffers in an arbitrary hardware format (any sample rate / channel count) into
/// 16 kHz mono Float32 samples — the format every transcription engine in the app consumes.
///
/// One instance is bound to one input format; create a new one whenever the input format changes.
/// Not thread-safe: call `resample` from a single thread (the audio tap thread).
final class AudioResampler {
    /// 16 kHz mono Float32, non-interleaved.
    static let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("16 kHz mono Float32 is a valid AVAudioFormat")
        }
        return format
    }()

    let inputFormat: AVAudioFormat
    /// Mono at the input sample rate — what we hand to AVAudioConverter after downmixing ourselves.
    private let monoInputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// Reused scratch buffer for the downmixed input (grown on demand).
    private var monoScratch: AVAudioPCMBuffer?

    /// Fails with `AudioCaptureError.unsupportedInputFormat` when Core Audio cannot convert from `inputFormat`.
    init(inputFormat: AVAudioFormat) throws {
        try AudioResampler.validate(inputFormat)
        // Downmixing is done by hand (see `downmixToMono`): AVAudioConverter's own channel mapping takes
        // only the left channel of a stereo input and produces pure silence for 4-channel interfaces —
        // both verified on real hardware. So the converter only ever sees mono and does sample-rate
        // conversion.
        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoInputFormat, to: AudioResampler.targetFormat) else {
            throw AudioCaptureError.unsupportedInputFormat(inputFormat.description)
        }
        self.inputFormat = inputFormat
        self.monoInputFormat = monoInputFormat
        self.converter = converter
    }
    /// Throws `AudioCaptureError.invalidInputFormat` when the format is one AVFAudio would assert on
    /// (0 Hz sample rate or 0 channels — what the input node reports when no input device is ready).
    static func validate(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat(format.description)
        }
    }

    /// Resample one tap buffer. Returns 16 kHz mono samples (possibly fewer or slightly more than
    /// the nominal ratio, because the converter buffers a few frames internally between calls).
    func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        // A buffer in a different format than the converter was built for means the hardware changed
        // underneath us. Dropping it is far better than handing AVAudioConverter a mismatched buffer.
        guard buffer.format.sampleRate == inputFormat.sampleRate,
              buffer.format.channelCount == inputFormat.channelCount else {
            throw AudioCaptureError.inputFormatChanged(
                expected: inputFormat.description, actual: buffer.format.description
            )
        }

        let mono = try downmixToMono(buffer)

        let ratio = AudioResampler.targetFormat.sampleRate / inputFormat.sampleRate
        // Slack so frames the converter carried over from previous calls have room to come out.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioResampler.targetFormat, frameCapacity: capacity) else {
            return []
        }

        // Feed the input buffer exactly once, then report "no more data for now". Returning the same
        // buffer every time the converter asks (the naive pattern) duplicates audio whenever the
        // converter needs a few extra frames to fill its output.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return mono
        }

        if status == .error {
            throw AudioCaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        guard let channelData = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }

    /// Mix an N-channel Float32 buffer down to mono at the same sample rate.
    ///
    /// Channels are averaged, but channels that are pure digital silence in this buffer are left out of
    /// the average: a 4-input interface typically exposes unused/loopback channels as exact zeros, and
    /// averaging them in would only make the one microphone quieter. A mono buffer is passed through
    /// untouched. Handles both interleaved and de-interleaved layouts.
    func downmixToMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard let source = buffer.floatChannelData else {
            throw AudioCaptureError.conversionFailed("Input buffer is not Float32 PCM")
        }
        if channels == 1 && !buffer.format.isInterleaved {
            return buffer
        }

        if monoScratch == nil || monoScratch!.frameCapacity < AVAudioFrameCount(frames) {
            monoScratch = AVAudioPCMBuffer(pcmFormat: monoInputFormat, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
        }
        guard let mono = monoScratch, let dest = mono.floatChannelData?[0] else {
            throw AudioCaptureError.conversionFailed("Could not allocate mono buffer")
        }
        mono.frameLength = AVAudioFrameCount(frames)

        // Interleaved: floatChannelData[0] holds all channels with stride `channels`.
        // De-interleaved: floatChannelData[c] holds channel c.
        let interleaved = buffer.format.isInterleaved
        @inline(__always) func sample(_ channel: Int, _ frame: Int) -> Float {
            interleaved ? source[0][frame * channels + channel] : source[channel][frame]
        }

        // Which channels carry any signal at all in this buffer?
        var active: [Int] = []
        active.reserveCapacity(channels)
        for c in 0..<channels {
            var hasSignal = false
            for f in 0..<frames where sample(c, f) != 0 { hasSignal = true; break }
            if hasSignal { active.append(c) }
        }

        if active.isEmpty {
            for f in 0..<frames { dest[f] = 0 }
        } else if active.count == 1 {
            let c = active[0]
            for f in 0..<frames { dest[f] = sample(c, f) }
        } else {
            let scale = 1 / Float(active.count)
            for f in 0..<frames {
                var sum: Float = 0
                for c in active { sum += sample(c, f) }
                dest[f] = sum * scale
            }
        }
        return mono
    }
}
