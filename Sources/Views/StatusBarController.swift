import AppKit
import SwiftUI
import Combine
import ServiceManagement

extension Notification.Name {
    static let openSetupWindow = Notification.Name("openSetupWindow")
}

@MainActor
class StatusBarController {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let appState = AppState.shared
    private weak var dictationController: DictationController?
    private var spinnerTimer: Timer?
    private var spinnerRotation: CGFloat = 0
    private var isSpinnerActive = false

    func setup(dictationController: DictationController?) {
        self.dictationController = dictationController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }
        button.imagePosition = .imageOnly
        updateIcon(for: .idle)

        setupMenu()
        observeState()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status line (read-only)
        let statusText: String
        switch appState.recordingState {
        case .idle:
            if let model = appState.currentlyLoadedModel {
                statusText = "Ready – \(model.displayName)"
            } else {
                statusText = "No model loaded"
            }
        case .loadingModel:
            statusText = "Loading model..."
        case .recording:
            statusText = "Recording..."
        case .transcribing:
            statusText = "Transcribing..."
        case .refining:
            statusText = "Refining with AI..."
        }

        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Model submenu
        let modelMenu = NSMenu()
        for model in TranscriptionModel.allCases {
            let isDownloaded = appState.downloadedModels.contains(model)
            let title = isDownloaded ? model.displayName : "\(model.displayName) ↓"
            let item = NSMenuItem(
                title: title,
                action: #selector(modelSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model
            item.state = (model == appState.selectedModel && isDownloaded) ? .on : .off
            modelMenu.addItem(item)
        }

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Hotkey submenu
        let hotkeyMenu = NSMenu()
        let modeSuffix = HotkeyOption.isToggleMode ? "(press twice)" : "(hold)"
        let currentSaved = HotkeyOption.saved
        let currentComboId = HotkeyOption.savedActiveCustomComboId

        // Presets (exclude .custom — it's represented by the combo items below)
        for option in HotkeyOption.allCases where option != .custom {
            let item = NSMenuItem(
                title: "\(option.keyName) \(modeSuffix)",
                action: #selector(hotkeySelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = (option == currentSaved) ? .on : .off
            hotkeyMenu.addItem(item)
        }

        // Custom combos
        let customCombos = HotkeyOption.savedCustomCombos
        if !customCombos.isEmpty {
            hotkeyMenu.addItem(NSMenuItem.separator())
            for combo in customCombos {
                let item = NSMenuItem(
                    title: "\(combo.displayName) \(modeSuffix)",
                    action: #selector(customComboSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = combo.id.uuidString as NSString
                item.state = (currentSaved == .custom && currentComboId == combo.id) ? .on : .off
                hotkeyMenu.addItem(item)
            }
        }

        hotkeyMenu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: "Press twice (toggle)",
            action: #selector(togglePressTwice(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = HotkeyOption.isToggleMode ? .on : .off
        hotkeyMenu.addItem(toggleItem)

        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // Quick Add Word
        let quickAddItem = NSMenuItem(
            title: "Add Word...",
            action: #selector(showQuickAdd),
            keyEquivalent: ""
        )
        quickAddItem.target = self
        menu.addItem(quickAddItem)

        // History
        let historyItem = NSMenuItem(
            title: "History...",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        // Settings menu item
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Speak2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openManageModels() {
        NotificationCenter.default.post(name: .openSetupWindow, object: nil)
    }

    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? TranscriptionModel else { return }

        let isDownloaded = appState.downloadedModels.contains(model)

        if isDownloaded {
            // Switch to this model
            appState.selectedModel = model
            TranscriptionModel.saved = model

            // Update checkmarks
            if let menu = sender.menu {
                for item in menu.items {
                    let itemModel = item.representedObject as? TranscriptionModel
                    item.state = (itemModel == model) ? .on : .off
                }
            }

            // Load the model
            Task {
                do {
                    try await dictationController?.loadModel(model)
                } catch {
                    appState.lastError = error.localizedDescription
                }
            }
        } else {
            // Open setup window to download
            NotificationCenter.default.post(name: .openSetupWindow, object: nil)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    @objc private func hotkeySelected(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? HotkeyOption else { return }
        dictationController?.updateHotkey(option)
        setupMenu()
    }

    @objc private func customComboSelected(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? NSString,
              let uuid = UUID(uuidString: idString as String) else { return }
        HotkeyOption.savedActiveCustomComboId = uuid
        dictationController?.updateHotkey(.custom)
        setupMenu()
    }

    @objc private func togglePressTwice(_ sender: NSMenuItem) {
        let newValue = !HotkeyOption.isToggleMode
        HotkeyOption.isToggleMode = newValue
        NotificationCenter.default.post(name: .hotkeyToggleModeChanged, object: nil)
        setupMenu()
    }

    @objc private func showQuickAdd() {
        NotificationCenter.default.post(name: .showQuickAddWord, object: nil)
    }

    @objc private func openDictionary() {
        NotificationCenter.default.post(name: .openDictionaryWindow, object: nil)
    }

    @objc private func openHistory() {
        NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    private func observeState() {
        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
                self?.setupMenu()  // Update status line
            }
            .store(in: &cancellables)

        // Rebuild menu when downloaded models change
        appState.$downloadedModels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)

        // Rebuild menu when selected model changes
        appState.$selectedModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)

        // Rebuild menu when currently loaded model changes
        appState.$currentlyLoadedModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: RecordingState) {
        guard let button = statusItem?.button else { return }

        // Stop spinner if not loading
        if state != .loadingModel {
            stopSpinner()
        }

        let symbolName: String
        let color: NSColor?

        switch state {
        case .idle:
            symbolName = "mic"
            color = nil  // Use template mode
        case .loadingModel:
            symbolName = "arrow.triangle.2.circlepath"
            color = .systemYellow
            startSpinner()
            return  // Spinner handles icon updates
        case .recording:
            symbolName = "mic.fill"
            color = .systemRed
        case .transcribing:
            symbolName = "ellipsis.circle"
            color = .systemCyan
        case .refining:
            symbolName = "sparkles"
            color = .systemPurple
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        if let color = color {
            // Create colored image for active states
            let colorConfig = config.applying(.init(paletteColors: [color]))
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Speak2")?
                .withSymbolConfiguration(colorConfig) {
                image.isTemplate = false
                button.image = image
            }
        } else {
            // Use template mode for idle state (adapts to light/dark)
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Speak2")?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                button.image = image
            }
        }
    }

    private func startSpinner() {
        guard spinnerTimer == nil else { return }
        isSpinnerActive = true
        spinnerRotation = 0
        updateSpinnerIcon()

        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isSpinnerActive else { return }
                self.spinnerRotation += 30
                if self.spinnerRotation >= 360 {
                    self.spinnerRotation = 0
                }
                self.updateSpinnerIcon()
            }
        }
    }

    private func stopSpinner() {
        isSpinnerActive = false
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinnerRotation = 0
    }

    private func updateSpinnerIcon() {
        guard isSpinnerActive, let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let colorConfig = config.applying(.init(paletteColors: [.systemYellow]))

        guard let baseImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Loading")?
            .withSymbolConfiguration(colorConfig) else { return }

        // Create rotated image
        let size = baseImage.size
        let rotatedImage = NSImage(size: size)
        rotatedImage.lockFocus()

        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: spinnerRotation)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()

        baseImage.draw(in: NSRect(origin: .zero, size: size))
        rotatedImage.unlockFocus()

        rotatedImage.isTemplate = false
        button.image = rotatedImage
    }
}
