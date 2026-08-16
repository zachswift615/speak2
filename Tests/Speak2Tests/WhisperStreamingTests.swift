import AVFoundation
import XCTest
@testable import Speak2

final class WhisperStreamingTests: XCTestCase {

    // MARK: - AudioSampleBuffer Tests

    func testAppendAndSnapshot() {
        let buffer = AudioSampleBuffer()
        buffer.append([1.0, 2.0, 3.0])
        let snap = buffer.snapshot()
        XCTAssertEqual(snap, [1.0, 2.0, 3.0])
    }

    func testCount() {
        let buffer = AudioSampleBuffer()
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(buffer.count, 5)
    }

    func testReset() {
        let buffer = AudioSampleBuffer()
        buffer.append([1.0, 2.0, 3.0])
        buffer.reset()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.snapshot(), [])
    }

    func testMultipleAppends() {
        let buffer = AudioSampleBuffer()
        buffer.append([1.0, 2.0])
        buffer.append([3.0, 4.0])
        buffer.append([5.0])
        XCTAssertEqual(buffer.snapshot(), [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    func testSnapshotIsACopy() {
        let buffer = AudioSampleBuffer()
        buffer.append([1.0, 2.0, 3.0])
        var snap = buffer.snapshot()
        snap[0] = 99.0
        // Original buffer should be unaffected
        XCTAssertEqual(buffer.snapshot(), [1.0, 2.0, 3.0])
    }

    // MARK: - StreamingTextSnapshot Tests

    func testUpdateAndRead() {
        let snapshot = StreamingTextSnapshot()
        snapshot.update(confirmed: "Hello", unconfirmed: "world")
        let result = snapshot.read()
        XCTAssertEqual(result.confirmed, "Hello")
        XCTAssertEqual(result.unconfirmed, "world")
    }

    func testStreamingTextSnapshotReset() {
        let snapshot = StreamingTextSnapshot()
        snapshot.update(confirmed: "Hello", unconfirmed: "world")
        snapshot.reset()
        let result = snapshot.read()
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "")
    }

    func testInitialState() {
        let snapshot = StreamingTextSnapshot()
        let result = snapshot.read()
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "")
    }

    // MARK: - diffWords Tests

    func testEmptyPrevious() {
        let result = diffWords(previous: "", current: "Hello world")
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "Hello world")
    }

    func testIdenticalText() {
        let result = diffWords(previous: "Hello world", current: "Hello world")
        XCTAssertEqual(result.confirmed, "Hello world")
        XCTAssertEqual(result.unconfirmed, "")
    }

    func testCommonPrefix() {
        let result = diffWords(previous: "Hello world", current: "Hello there")
        XCTAssertEqual(result.confirmed, "Hello")
        XCTAssertEqual(result.unconfirmed, "there")
    }

    func testCompletelyDifferent() {
        let result = diffWords(previous: "Hello", current: "Goodbye")
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "Goodbye")
    }

    func testCaseInsensitive() {
        let result = diffWords(previous: "hello World", current: "Hello WORLD")
        XCTAssertEqual(result.confirmed, "Hello WORLD")
        XCTAssertEqual(result.unconfirmed, "")
    }

    func testPunctuationTolerance() {
        let result = diffWords(previous: "Alright", current: "Alright, I am")
        XCTAssertEqual(result.confirmed, "Alright,")
        XCTAssertEqual(result.unconfirmed, "I am")
    }

    func testTrailingPunctuationVariation() {
        let result = diffWords(previous: "Hello world.", current: "Hello world, how")
        XCTAssertEqual(result.confirmed, "Hello world,")
        XCTAssertEqual(result.unconfirmed, "how")
    }

    func testEmptyCurrent() {
        let result = diffWords(previous: "Hello", current: "")
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "")
    }

    func testBothEmpty() {
        let result = diffWords(previous: "", current: "")
        XCTAssertEqual(result.confirmed, "")
        XCTAssertEqual(result.unconfirmed, "")
    }

    func testLongerPrevious() {
        let result = diffWords(previous: "Hello world how are you", current: "Hello world")
        XCTAssertEqual(result.confirmed, "Hello world")
        XCTAssertEqual(result.unconfirmed, "")
    }

    // MARK: - normalizeForComparison Tests

    func testBasicNormalization() {
        XCTAssertEqual(normalizeForComparison("Hello"), "hello")
    }

    func testPunctuationStripping() {
        XCTAssertEqual(normalizeForComparison("Hello,"), "hello")
        XCTAssertEqual(normalizeForComparison("world."), "world")
        XCTAssertEqual(normalizeForComparison("test?!"), "test")
    }

    func testNoPunctuation() {
        XCTAssertEqual(normalizeForComparison("hello"), "hello")
    }

    func testOnlyPunctuation() {
        XCTAssertEqual(normalizeForComparison("..."), "")
    }
}

// MARK: - AudioSampleBuffer.suffix (used by live-transcription passes on long recordings)

final class AudioSampleBufferSuffixTests: XCTestCase {
    func testSuffixReturnsTail() {
        let buffer = AudioSampleBuffer()
        buffer.append((0..<10).map(Float.init))
        XCTAssertEqual(buffer.suffix(3), [7, 8, 9])
    }

    func testSuffixLargerThanCountReturnsAll() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2, 3])
        XCTAssertEqual(buffer.suffix(10), [1, 2, 3])
    }

    func testSuffixOnEmptyBuffer() {
        XCTAssertEqual(AudioSampleBuffer().suffix(5), [])
    }

    func testWriteSamplesToTempWAVRoundTrips() throws {
        let samples: [Float] = (0..<16000).map { Float(sin(Double($0) / 50)) }
        let url = try writeSamplesToTempWAV(samples, filenamePrefix: "test_stream")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Int(file.length), samples.count)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        XCTAssertEqual(pcm.floatChannelData![0][100], samples[100], accuracy: 1e-6)
    }
}
