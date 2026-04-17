import SwiftUI
import AVFoundation
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var selectedHotkey: HotkeyOption = HotkeyOption.saved
    @State private var isToggleMode: Bool = HotkeyOption.isToggleMode
    @State private var launchAtLogin: Bool = false
    @State private var isCapturingKey = false
    @State private var customCombos: [CustomHotkeyCombo] = HotkeyOption.savedCustomCombos
    @State private var activeComboId: UUID? = HotkeyOption.savedActiveCustomComboId

    @AppStorage("clipboardRestoreDelayMs") private var clipboardRestoreDelayMs: Int = TextInjector.defaultFallbackDelayMs

    private var presets: [HotkeyOption] {
        HotkeyOption.allCases.filter { $0 != .custom }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Permissions Section
                SettingsSection(title: "Permissions") {
                    VStack(spacing: 12) {
                        PermissionSettingsRow(
                            title: "Accessibility",
                            description: "Required for global hotkey detection",
                            isGranted: appState.hasAccessibilityPermission,
                            action: requestAccessibility
                        )

                        Divider()

                        PermissionSettingsRow(
                            title: "Microphone",
                            description: "Required for voice recording",
                            isGranted: appState.hasMicrophonePermission,
                            action: requestMicrophone
                        )
                    }
                }

                // Hotkey Section
                SettingsSection(title: "Trigger Hotkey") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(hotkeyInstructionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)

                        // Presets
                        ForEach(presets, id: \.self) { option in
                            hotkeyRow(
                                label: option.keyName,
                                isSelected: selectedHotkey == option,
                                action: { selectPreset(option) }
                            )
                        }

                        if !customCombos.isEmpty {
                            Divider()
                                .padding(.vertical, 4)

                            Text("Custom")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Custom combos
                        ForEach(customCombos) { combo in
                            HStack(spacing: 8) {
                                hotkeyRow(
                                    label: combo.displayName,
                                    isSelected: selectedHotkey == .custom && activeComboId == combo.id,
                                    action: { selectCustomCombo(combo) }
                                )

                                Button {
                                    deleteCombo(combo)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this hotkey")
                            }
                        }

                        // Add / Capture
                        if isCapturingKey {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.accentColor, lineWidth: 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(NSColor.textBackgroundColor))
                                        )

                                    KeyCaptureView(
                                        isCapturing: true,
                                        onCapture: { combo in
                                            addCapturedCombo(combo)
                                        },
                                        onCancel: {
                                            isCapturingKey = false
                                            NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])
                                        }
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                    Text("Press a key or combo (Esc to cancel)...")
                                        .foregroundStyle(.secondary)
                                        .font(.system(.body, design: .monospaced))
                                }
                                .frame(height: 28)

                                Button("Cancel") {
                                    isCapturingKey = false
                                    NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                        } else {
                            Button {
                                isCapturingKey = true
                                NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": true])
                            } label: {
                                Label("Add Custom Combo...", systemImage: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 4)
                        }

                        Divider()

                        Toggle("Press twice (toggle)", isOn: $isToggleMode)
                            .onChange(of: isToggleMode) { _, newValue in
                                HotkeyOption.isToggleMode = newValue
                                NotificationCenter.default.post(
                                    name: .hotkeyToggleModeChanged,
                                    object: nil
                                )
                            }

                        Text("When enabled, press the hotkey twice quickly to start recording, and twice again to stop. When disabled, hold the key to record.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Startup Section
                SettingsSection(title: "Startup") {
                    Toggle("Launch Speak2 at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }

                // Live Transcription Section
                SettingsSection(title: "Live Transcription") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show live transcription while recording", isOn: $appState.liveTranscriptionEnabled)

                        Text("Displays a floating overlay with real-time transcription text while you hold the hotkey.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Paste Behavior Section
                SettingsSection(title: "Paste Behavior") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Clipboard restore delay")
                                .fontWeight(.medium)
                            Spacer()
                            TextField(
                                "",
                                value: $clipboardRestoreDelayMs,
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: clipboardRestoreDelayMs) { _, newValue in
                                let clamped = min(max(newValue, TextInjector.minFallbackDelayMs), TextInjector.maxFallbackDelayMs)
                                if clamped != newValue {
                                    clipboardRestoreDelayMs = clamped
                                }
                            }
                            Text("ms")
                                .foregroundStyle(.secondary)
                        }

                        Text("How long Speak2 waits before restoring your original clipboard after pasting. Increase this (e.g. 500–1000ms) if you paste into remote/SSH terminals and sometimes see the original clipboard contents appear instead of your transcription. Range: \(TextInjector.minFallbackDelayMs)–\(TextInjector.maxFallbackDelayMs)ms.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // About Section
                SettingsSection(title: "About") {
                    HStack {
                        Text("Speak2")
                            .fontWeight(.medium)
                        Spacer()
                        Text("v\(AppState.appVersion)")
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            checkPermissions()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            customCombos = HotkeyOption.savedCustomCombos
            activeComboId = HotkeyOption.savedActiveCustomComboId
        }
        .onDisappear {
            if isCapturingKey {
                isCapturingKey = false
                NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func hotkeyRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.body)
                Text(label)
                    .font(.system(.body, design: .default))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func selectPreset(_ option: HotkeyOption) {
        if isCapturingKey {
            isCapturingKey = false
            NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])
        }
        selectedHotkey = option
        HotkeyOption.saved = option
        NotificationCenter.default.post(
            name: .hotkeyChanged,
            object: nil,
            userInfo: ["hotkey": option]
        )
    }

    private func selectCustomCombo(_ combo: CustomHotkeyCombo) {
        if isCapturingKey {
            isCapturingKey = false
            NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])
        }
        selectedHotkey = .custom
        activeComboId = combo.id
        HotkeyOption.saved = .custom
        HotkeyOption.savedActiveCustomComboId = combo.id
        NotificationCenter.default.post(
            name: .hotkeyChanged,
            object: nil,
            userInfo: ["hotkey": HotkeyOption.custom]
        )
    }

    private func addCapturedCombo(_ captured: CapturedCombo) {
        let combo = CustomHotkeyCombo(
            triggerKeycode: captured.triggerKeycode,
            triggerIsModifier: captured.triggerIsModifier,
            requiredModifierFlags: captured.requiredModifierFlags,
            displayName: captured.displayName
        )
        customCombos.append(combo)
        HotkeyOption.savedCustomCombos = customCombos

        isCapturingKey = false
        NotificationCenter.default.post(name: .hotkeyCaptureModeChanged, object: nil, userInfo: ["capturing": false])

        // Auto-select the newly added combo
        selectCustomCombo(combo)
    }

    private func deleteCombo(_ combo: CustomHotkeyCombo) {
        customCombos.removeAll { $0.id == combo.id }
        HotkeyOption.savedCustomCombos = customCombos

        // If deleted combo was active, fall back to fnKey
        if activeComboId == combo.id {
            activeComboId = nil
            HotkeyOption.savedActiveCustomComboId = nil
            selectPreset(.fnKey)
        }
    }

    // MARK: - Helpers

    private var hotkeyInstructionText: String {
        if isToggleMode {
            return "Press this key twice to start recording, press twice again to transcribe"
        } else {
            return "Hold this key to start recording, release to transcribe"
        }
    }

    private func checkPermissions() {
        appState.hasAccessibilityPermission = HotkeyManager.checkAccessibilityPermission()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            appState.hasMicrophonePermission = true
        default:
            appState.hasMicrophonePermission = false
        }
    }

    private func requestAccessibility() {
        HotkeyManager.requestAccessibilityPermission()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if HotkeyManager.checkAccessibilityPermission() {
                Task { @MainActor in
                    appState.hasAccessibilityPermission = true
                }
                timer.invalidate()
            }
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                appState.hasMicrophonePermission = granted
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            content
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}

// MARK: - Permission Row for Settings

struct PermissionSettingsRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Notification for hotkey changes

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
    static let hotkeyToggleModeChanged = Notification.Name("hotkeyToggleModeChanged")
    static let hotkeyCaptureModeChanged = Notification.Name("hotkeyCaptureModeChanged")
}
