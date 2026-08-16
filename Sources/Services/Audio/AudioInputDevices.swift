import AVFoundation
import CoreAudio
import Foundation
import os

/// A microphone / audio input device as seen by Core Audio.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// Persistent identifier (`kAudioDevicePropertyDeviceUID`) — stable across reboots and reconnects,
    /// unlike `AudioDeviceID`, so this is what settings store.
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
    /// e.g. "Built-in", "Bluetooth", "USB", "Virtual"
    let transport: String
    var id: String { uid }
}

/// User preference for which microphone to record from. Persisted in UserDefaults.
enum AudioInputPreference {
    static let userDefaultsKey = "preferredInputDeviceUID"

    /// The selected device UID, or nil for "System Default".
    static var savedUID: String? {
        get { UserDefaults.standard.string(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    static let keepWarmKey = "microphoneKeepWarmSeconds"
    /// How long to keep the microphone running after a dictation so the next one starts instantly.
    /// 0 = release the microphone immediately (default). Trade-off: the system's mic-in-use indicator
    /// stays on for the window and Bluetooth headsets stay in their headset profile.
    static var keepWarmSeconds: Int {
        get { UserDefaults.standard.integer(forKey: keepWarmKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepWarmKey) }
    }
}

/// Enumerates audio input devices and publishes changes (device plugged/unplugged, default changed).
@MainActor
final class AudioInputDeviceMonitor: ObservableObject {
    static let shared = AudioInputDeviceMonitor()

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var systemDefault: AudioInputDevice?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listening = false

    private init() {
        refresh()
        startListening()
    }

    func refresh() {
        devices = AudioInputDevices.all()
        systemDefault = AudioInputDevices.systemDefault()
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}

/// Stateless Core Audio queries for input devices.
enum AudioInputDevices {
    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { device(for: $0) }
    }

    static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return device(for: deviceID)
    }

    /// Look up a device by persistent UID; nil if it isn't currently connected.
    static func device(withUID uid: String) -> AudioInputDevice? {
        all().first { $0.uid == uid }
    }

    /// Resolve the user's preference to a concrete device: the chosen device if connected, else the
    /// system default (and `usedFallback` = true so the caller can log/report it).
    static func resolvePreferred(uid: String?) -> (device: AudioInputDevice?, usedFallback: Bool) {
        if let uid, let chosen = device(withUID: uid) {
            return (chosen, false)
        }
        return (systemDefault(), uid != nil)
    }

    // MARK: - Core Audio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// Returns nil for devices without input channels (speakers, output-only interfaces).
    static func device(for deviceID: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(deviceID) > 0,
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioObjectPropertyName) else {
            return nil
        }
        return AudioInputDevice(uid: uid, name: name, deviceID: deviceID, transport: transportName(deviceID))
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return "Unknown" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        default: return "Unknown"
        }
    }
}
