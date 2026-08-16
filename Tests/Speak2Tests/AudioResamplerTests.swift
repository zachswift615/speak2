import AVFoundation
import XCTest
@testable import Speak2

final class AudioResamplerTests: XCTestCase {

    // MARK: - Helpers

    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved)!
    }

    /// Split a per-sample generator into tap-sized PCM buffers in `format`.
    private func makeBuffers(
        format: AVAudioFormat,
        seconds: Double,
        chunk: AVAudioFrameCount = 4096,
        generator: (Double) -> Float
    ) -> [AVAudioPCMBuffer] {
        let totalFrames = Int(format.sampleRate * seconds)
        var buffers: [AVAudioPCMBuffer] = []
        var frame = 0
        while frame < totalFrames {
            let count = min(Int(chunk), totalFrames - frame)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let t = Double(frame + i) / format.sampleRate
                let value = generator(t)
                if format.isInterleaved {
                    let ptr = buffer.floatChannelData![0]
                    for ch in 0..<Int(format.channelCount) {
                        ptr[i * Int(format.channelCount) + ch] = value
                    }
                } else {
                    for ch in 0..<Int(format.channelCount) {
                        buffer.floatChannelData![ch][i] = value
                    }
                }
            }
            buffers.append(buffer)
            frame += count
        }
        return buffers
    }

    private func resampleAll(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> [Float] {
        let resampler = try AudioResampler(inputFormat: format)
        var out: [Float] = []
        for b in buffers { out += try resampler.resample(b) }
        return out
    }

    // MARK: - Sample-count correctness across every hardware format we expect to meet
    // (48 kHz built-in mic, 44.1 kHz USB interfaces, 24 kHz / 16 kHz / 8 kHz Bluetooth headset profiles)

    func testOutputLengthMatchesTargetRateForCommonInputFormats() throws {
        let cases: [(Double, AVAudioChannelCount)] = [
            (48000, 1), (48000, 2), (44100, 1), (44100, 2), (24000, 1), (16000, 1), (8000, 1), (96000, 2)
        ]
        for (rate, channels) in cases {
            let format = makeFormat(sampleRate: rate, channels: channels)
            let buffers = makeBuffers(format: format, seconds: 2.0) { t in Float(sin(2 * .pi * 440 * t)) * 0.5 }
            let out = try resampleAll(buffers, format: format)
            // 2 s of audio → 32 000 samples at 16 kHz. Allow the converter's small internal latency.
            XCTAssertEqual(out.count, 32_000, accuracy: 400, "rate=\(rate) ch=\(channels)")
        }
    }

    // MARK: - No duplicated or dropped audio across buffer boundaries

    /// A slow ramp resampled correctly is monotonic. Feeding the same input buffer to the converter
    /// twice (the classic AVAudioConverter input-block mistake) replays ~85 ms of audio and shows up
    /// as a large backwards jump.
    func testRampStaysMonotonicAcrossBufferBoundaries() throws {
        for rate in [48000.0, 44100.0, 24000.0, 16000.0] {
            let format = makeFormat(sampleRate: rate, channels: 1)
            let buffers = makeBuffers(format: format, seconds: 1.0) { t in Float(t) }
            let out = try resampleAll(buffers, format: format)
            // Skip the first/last few samples where the resampling filter rings.
            let body = out.dropFirst(64).dropLast(64)
            var previous = body.first ?? 0
            for (i, sample) in body.enumerated() {
                XCTAssertGreaterThanOrEqual(sample, previous - 0.002,
                                            "rate=\(rate): backwards jump at 16k sample \(i)")
                previous = sample
            }
        }
    }

    func testToneFrequencyIsPreservedAfterResampling() throws {
        for rate in [48000.0, 44100.0, 24000.0] {
            let format = makeFormat(sampleRate: rate, channels: 2)
            let buffers = makeBuffers(format: format, seconds: 2.0) { t in Float(sin(2 * .pi * 440 * t)) }
            let out = try resampleAll(buffers, format: format)
            // Count positive-going zero crossings in the middle second → ~440
            let middle = Array(out[8000..<24000])
            var crossings = 0
            for i in 1..<middle.count where middle[i - 1] < 0 && middle[i] >= 0 { crossings += 1 }
            XCTAssertEqual(Double(crossings), 440, accuracy: 10, "rate=\(rate)")
        }
    }

    // MARK: - Interleaved input

    func testInterleavedStereoInputIsSupported() throws {
        let format = makeFormat(sampleRate: 48000, channels: 2, interleaved: true)
        let buffers = makeBuffers(format: format, seconds: 0.5) { t in Float(sin(2 * .pi * 440 * t)) }
        let out = try resampleAll(buffers, format: format)
        XCTAssertEqual(out.count, 8_000, accuracy: 300)
    }

    // MARK: - Defensive behaviour

    func testEmptyBufferProducesNoSamples() throws {
        let format = makeFormat(sampleRate: 48000, channels: 1)
        let resampler = try AudioResampler(inputFormat: format)
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        empty.frameLength = 0
        XCTAssertEqual(try resampler.resample(empty), [])
    }

    func testBufferInDifferentFormatIsRejectedNotCrashed() throws {
        let resampler = try AudioResampler(inputFormat: makeFormat(sampleRate: 48000, channels: 1))
        let other = makeFormat(sampleRate: 24000, channels: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 1024)!
        buffer.frameLength = 1024
        XCTAssertThrowsError(try resampler.resample(buffer)) { error in
            guard case AudioCaptureError.inputFormatChanged = error else {
                return XCTFail("expected inputFormatChanged, got \(error)")
            }
        }
    }

    func testInvalidHardwareFormatIsRejected() {
        // AVAudioFormat() is the 0 Hz / 0-channel format the input node reports when no device is ready.
        // AVFAudio raises an NSException if a tap is installed with it; we must refuse it up front.
        let invalid = AVAudioFormat()
        XCTAssertThrowsError(try AudioResampler.validate(invalid)) { error in
            guard case AudioCaptureError.invalidInputFormat = error else {
                return XCTFail("expected invalidInputFormat, got \(error)")
            }
        }
        XCTAssertThrowsError(try AudioResampler(inputFormat: invalid))
    }

    func testTargetFormatIs16kMonoFloat() {
        let f = AudioResampler.targetFormat
        XCTAssertEqual(f.sampleRate, 16000)
        XCTAssertEqual(f.channelCount, 1)
        XCTAssertEqual(f.commonFormat, .pcmFormatFloat32)
    }
}

// MARK: - Downmix (regression: AVAudioConverter alone dropped the right channel of stereo inputs and
// produced pure silence for 4-channel interfaces such as a Scarlett 2i2 4th Gen)

final class AudioResamplerDownmixTests: XCTestCase {

    private func format(_ rate: Double, _ channels: AVAudioChannelCount, interleaved: Bool = false) -> AVAudioFormat {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        }
        // >2 channels need an explicit layout — this is how Core Audio describes multi-input interfaces
        // (a Scarlett 2i2 4th Gen reports 4 ch, DiscreteInOrder).
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
    }

    /// Buffer with a tone on `hotChannels` only; every other channel is exact digital zero.
    private func toneBuffer(_ format: AVAudioFormat, hotChannels: Set<Int>, frames: Int = 4096) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        for f in 0..<frames {
            let value = Float(sin(Double(f) * 0.05)) * 0.5
            for c in 0..<channels {
                let v: Float = hotChannels.contains(c) ? value : 0
                if format.isInterleaved { buffer.floatChannelData![0][f * channels + c] = v }
                else { buffer.floatChannelData![c][f] = v }
            }
        }
        return buffer
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func testFourChannelInputWithMicOnAnySingleChannelIsHeard() throws {
        for rate in [44100.0, 48000.0] {
            let fmt = format(rate, 4)
            for hot in 0..<4 {
                let resampler = try AudioResampler(inputFormat: fmt)
                let out = try resampler.resample(toneBuffer(fmt, hotChannels: [hot]))
                XCTAssertGreaterThan(rms(out), 0.3, "rate=\(rate) mic on channel \(hot) must not be silenced")
            }
        }
    }

    func testStereoInputWithMicOnRightChannelIsHeard() throws {
        for interleaved in [false, true] {
            let fmt = format(48000, 2, interleaved: interleaved)
            let resampler = try AudioResampler(inputFormat: fmt)
            let right = try resampler.resample(toneBuffer(fmt, hotChannels: [1]))
            XCTAssertGreaterThan(rms(right), 0.3, "interleaved=\(interleaved)")
        }
    }

    func testSilentChannelsDoNotDiluteTheActiveOne() throws {
        let fmt = format(48000, 4)
        let resampler = try AudioResampler(inputFormat: fmt)
        let single = try resampler.resample(toneBuffer(fmt, hotChannels: [0]))
        let mono = try AudioResampler(inputFormat: format(48000, 1)).resample(toneBuffer(format(48000, 1), hotChannels: [0]))
        XCTAssertEqual(rms(single), rms(mono), accuracy: 0.02, "one live channel of four should keep its level")
    }

    func testCorrelatedChannelsAreAveragedNotSummed() throws {
        let fmt = format(48000, 2)
        let resampler = try AudioResampler(inputFormat: fmt)
        let both = try resampler.resample(toneBuffer(fmt, hotChannels: [0, 1]))
        let mono = try AudioResampler(inputFormat: format(48000, 1)).resample(toneBuffer(format(48000, 1), hotChannels: [0]))
        XCTAssertEqual(rms(both), rms(mono), accuracy: 0.02, "identical L/R should come out at the same level, not doubled")
    }

    func testAllSilentChannelsProduceSilence() throws {
        let fmt = format(48000, 4)
        let resampler = try AudioResampler(inputFormat: fmt)
        let out = try resampler.resample(toneBuffer(fmt, hotChannels: []))
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }
}
