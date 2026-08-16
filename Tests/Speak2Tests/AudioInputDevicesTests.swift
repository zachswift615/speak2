import XCTest
@testable import Speak2

final class AudioInputDevicesTests: XCTestCase {

    func testEnumeratesInputDevicesWithStableIdentity() {
        let devices = AudioInputDevices.all()
        // Every Mac has at least a built-in microphone (CI runners may not — skip rather than fail).
        try? XCTSkipIf(devices.isEmpty, "No input devices on this machine")
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertNotEqual(device.deviceID, 0)
        }
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "UIDs must be unique")
    }

    func testSystemDefaultIsAmongInputDevices() throws {
        let devices = AudioInputDevices.all()
        try XCTSkipIf(devices.isEmpty, "No input devices on this machine")
        let def = try XCTUnwrap(AudioInputDevices.systemDefault())
        XCTAssertTrue(devices.contains(def))
    }

    func testResolvePreferredFallsBackToDefaultForUnknownUID() throws {
        try XCTSkipIf(AudioInputDevices.all().isEmpty, "No input devices on this machine")
        let (device, usedFallback) = AudioInputDevices.resolvePreferred(uid: "not-a-real-device-uid")
        XCTAssertTrue(usedFallback)
        XCTAssertEqual(device, AudioInputDevices.systemDefault())
    }

    func testResolvePreferredNilMeansSystemDefaultWithoutFallbackFlag() {
        let (device, usedFallback) = AudioInputDevices.resolvePreferred(uid: nil)
        XCTAssertFalse(usedFallback)
        XCTAssertEqual(device, AudioInputDevices.systemDefault())
    }

    func testResolvePreferredReturnsChosenDeviceWhenConnected() throws {
        let devices = AudioInputDevices.all()
        let chosen = try XCTUnwrap(devices.last)
        let (device, usedFallback) = AudioInputDevices.resolvePreferred(uid: chosen.uid)
        XCTAssertFalse(usedFallback)
        XCTAssertEqual(device, chosen)
    }
}
