import AVFoundation
import CoreAudio
import XCTest
@testable import Speak2

// MARK: - Permission handling (no hardware needed)

private final class FakePermissionProvider: MicrophonePermissionProviding, @unchecked Sendable {
    var status: AVAuthorizationStatus
    var grantOnRequest: Bool
    private(set) var requestCount = 0

    init(status: AVAuthorizationStatus, grantOnRequest: Bool = false) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    func authorizationStatus() -> AVAuthorizationStatus { status }
    func requestAccess() async -> Bool {
        requestCount += 1
        return grantOnRequest
    }
}

final class AudioCaptureServiceTests: XCTestCase {

    func testDeniedPermissionThrowsBeforeTouchingHardware() async {
        let provider = FakePermissionProvider(status: .denied)
        let service = AudioCaptureService(permissionProvider: provider)
        do {
            try await service.start { _ in }
            XCTFail("expected microphoneAccessDenied")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .microphoneAccessDenied)
        }
        let capturing = await service.isCapturing
        XCTAssertFalse(capturing)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testRestrictedPermissionThrows() async {
        let service = AudioCaptureService(permissionProvider: FakePermissionProvider(status: .restricted))
        do {
            try await service.start { _ in }
            XCTFail("expected microphoneAccessDenied")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .microphoneAccessDenied)
        }
    }

    func testUndeterminedPermissionIsRequestedAndDenialThrows() async {
        let provider = FakePermissionProvider(status: .notDetermined, grantOnRequest: false)
        let service = AudioCaptureService(permissionProvider: provider)
        do {
            try await service.start { _ in }
            XCTFail("expected microphoneAccessDenied")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .microphoneAccessDenied)
        }
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testStopWhenNotCapturingIsHarmless() async {
        let service = AudioCaptureService(permissionProvider: FakePermissionProvider(status: .denied))
        await service.stopAll()
        let capturing = await service.isCapturing
        XCTAssertFalse(capturing)
        let report = await service.lastSessionReport
        XCTAssertNil(report)
    }

    func testErrorsHaveUserFacingDescriptions() {
        let errors: [AudioCaptureError] = [
            .microphoneAccessDenied,
            .invalidInputFormat("0 ch, 0 Hz"),
            .unsupportedInputFormat("x"),
            .inputFormatChanged(expected: "a", actual: "b"),
            .conversionFailed("x"),
            .engineStartFailed("x"),
            .audioEngineException("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertFalse(error.localizedDescription.hasPrefix("The operation couldn"), "\(error) lacks a description")
        }
    }
}

// MARK: - Hardware regression test (opt-in)
//
// Reproduces the AirPods bug: the default input device changes while capture is running.
// AVAudioEngine stops itself and posts AVAudioEngineConfigurationChange; before AudioCaptureService,
// audio silently stopped flowing (or the app crashed on a stale tap format).
//
// Run with:  SPEAK2_AUDIO_HARDWARE_TESTS=1 swift test --filter AudioCaptureHardwareTests
// Requires microphone access for the test process and at least two audio input devices.

final class AudioCaptureHardwareTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEAK2_AUDIO_HARDWARE_TESTS"] == "1",
                          "Set SPEAK2_AUDIO_HARDWARE_TESTS=1 to run hardware capture tests")
    }

    func testCaptureDeliversSamplesFromDefaultInput() async throws {
        let service = AudioCaptureService()
        let buffer = AudioSampleBuffer()
        let live = expectation(description: "microphone live")
        live.assertForOverFulfill = true
        let token = try await service.start(
            onSamples: { buffer.append($0) },
            onMicrophoneLive: { live.fulfill() }
        )
        await fulfillment(of: [live], timeout: 3)
        try await Task.sleep(for: .seconds(1))
        let report = await service.stop(token)
        XCTAssertNotNil(report)
        XCTAssertGreaterThan(buffer.count, 8_000, "expected ≥0.5 s of 16 kHz audio in 1 s")
        XCTAssertNil(report?.failure)
        XCTAssertGreaterThanOrEqual(report?.leadingSilentSamples ?? -1, 0)
        XCTAssertEqual(report?.heardAudio, true, "a real microphone always has a noise floor")
    }

    /// The crash from issue #28 is an AVFAudio NSException raised when a tap format doesn't match the
    /// hardware. Confirm the exception shim turns that exact class of failure into a Swift error.
    func testAVFAudioFormatAssertionIsCaughtAsError() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        XCTAssertThrowsError(
            try withObjCExceptionsCaught {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: AVAudioFormat()) { _, _ in }
            }
        ) { error in
            guard let objc = error as? ObjCExceptionError else {
                return XCTFail("expected ObjCExceptionError, got \(error)")
            }
            XCTAssertTrue(objc.localizedDescription.contains("required condition is false"), objc.localizedDescription)
        }
    }

    /// A stale token (from a session that was already superseded) must never stop the live session.
    func testStaleTokenCannotStopNewerSession() async throws {
        let service = AudioCaptureService()
        let first = try await service.start { _ in }
        let buffer = AudioSampleBuffer()
        let second = try await service.start { buffer.append($0) }   // supersedes `first`
        XCTAssertNotEqual(first, second)

        await service.stop(first)                                       // stale: must be a no-op
        let stillCapturing = await service.isCapturing
        XCTAssertTrue(stillCapturing)

        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(buffer.count, 8_000, "second session should still be delivering audio")
        let report = await service.stop(second)
        XCTAssertNotNil(report)
        let capturing = await service.isCapturing
        XCTAssertFalse(capturing)
    }

    /// Pinning the input to a specific device must actually record from that device, and a device that
    /// delivers only digital zeros (BlackHole with nothing routed into it) must be reported as unheard.
    func testPreferredDeviceIsUsedAndSilentDeviceIsReported() async throws {
        guard let blackHole = AudioInputDevices.all().first(where: { $0.name.contains("BlackHole") }) else {
            throw XCTSkip("Needs a BlackHole virtual device")
        }
        let previous = AudioInputPreference.savedUID
        AudioInputPreference.savedUID = blackHole.uid
        defer { AudioInputPreference.savedUID = previous }

        let service = AudioCaptureService()
        let token = try await service.start(onSamples: { _ in })
        try await Task.sleep(for: .seconds(2))
        let stopped = await service.stop(token)
        let report = try XCTUnwrap(stopped)
        XCTAssertEqual(report.inputDeviceName, blackHole.name)
        XCTAssertFalse(report.usedFallbackDevice)
        XCTAssertGreaterThan(report.samplesDelivered, 8_000)
        XCTAssertFalse(report.heardAudio, "BlackHole with no signal should be pure digital silence")
    }

    /// With keep-warm on, the second start must reuse the running engine and deliver audio immediately;
    /// after the window expires the engine must be released.
    func testWarmEngineIsReusedAndThenExpires() async throws {
        let previous = AudioInputPreference.keepWarmSeconds
        AudioInputPreference.keepWarmSeconds = 3
        defer { AudioInputPreference.keepWarmSeconds = previous }

        let service = AudioCaptureService()
        let first = try await service.start(onSamples: { _ in })
        try await Task.sleep(for: .seconds(1))
        await service.stop(first)

        // Second start: should be instant (samples within a few tap buffers).
        let buffer = AudioSampleBuffer()
        let started = CFAbsoluteTimeGetCurrent()
        let second = try await service.start(onSamples: { buffer.append($0) })
        let startLatency = CFAbsoluteTimeGetCurrent() - started
        try await Task.sleep(for: .milliseconds(300))
        let early = buffer.count
        let report = await service.stop(second)
        XCTAssertLessThan(startLatency, 0.15, "warm start should not pay engine bring-up (took \(startLatency)s)")
        XCTAssertGreaterThan(early, 2_000, "warm engine should deliver audio right away")
        XCTAssertNil(report?.failure)

        // Let the warm window lapse; a cold start afterwards must still work.
        try await Task.sleep(for: .seconds(4))
        let third = try await service.start(onSamples: { _ in })
        try await Task.sleep(for: .milliseconds(500))
        let thirdReport = await service.stop(third)
        XCTAssertGreaterThan(thirdReport?.samplesDelivered ?? 0, 0)
        await service.stopAll()
    }

    func testCaptureSurvivesDefaultInputDeviceChange() async throws {
        let inputs = CoreAudioTestHelpers.inputDevices()
        let original = CoreAudioTestHelpers.defaultInputDevice()
        // Prefer a virtual/loopback device when available (fast, deterministic); else any other input.
        let candidates = inputs.filter { $0.id != original }
        guard let otherDevice = candidates.first(where: { $0.name.contains("BlackHole") }) ?? candidates.first else {
            throw XCTSkip("Need a second input device to simulate a device switch")
        }
        let other = otherDevice.id
        print("[HardwareTest] switching default input \(original) → \(otherDevice.name) (\(other))")
        defer { CoreAudioTestHelpers.setDefaultInputDevice(original) }

        let service = AudioCaptureService()
        let buffer = AudioSampleBuffer()
        let token = try await service.start { buffer.append($0) }
        try await Task.sleep(for: .seconds(1))
        let beforeSwitch = buffer.count
        XCTAssertGreaterThan(beforeSwitch, 0)

        // Rebuilding the engine after a device change takes ~1 s (settle delay + AVAudioEngine start),
        // so give each phase a 3 s window and require at least 0.5 s of audio in it.
        CoreAudioTestHelpers.setDefaultInputDevice(other)
        try await Task.sleep(for: .seconds(3))
        let afterSwitch = buffer.count

        CoreAudioTestHelpers.setDefaultInputDevice(original)
        try await Task.sleep(for: .seconds(3))
        let afterSwitchBack = buffer.count

        let report = await service.stop(token)
        print("[HardwareTest] before=\(beforeSwitch) after=\(afterSwitch) back=\(afterSwitchBack) report=\(String(describing: report))")
        XCTAssertNotNil(report)
        XCTAssertNil(report?.failure)
        XCTAssertGreaterThanOrEqual(report?.restarts ?? 0, 1, "engine should have been rebuilt after the device change")
        XCTAssertGreaterThan(afterSwitch, beforeSwitch + 8_000, "audio must keep flowing after the input device changes")
        XCTAssertGreaterThan(afterSwitchBack, afterSwitch + 8_000, "audio must keep flowing after switching back")
    }
}

enum CoreAudioTestHelpers {
    struct Device { let id: AudioDeviceID; let name: String }

    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil, &configSize)
            guard configSize > 0 else { return nil }
            let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(configSize))
            defer { list.deallocate() }
            AudioObjectGetPropertyData(id, &configAddress, 0, nil, &configSize, list)
            let channels = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return Device(id: id, name: name as String)
        }
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func setDefaultInputDevice(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }
}
