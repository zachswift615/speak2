import Foundation
import SwiftUI

enum RecordingState {
    case idle
    case loadingModel
    /// Hotkey pressed; the microphone is being brought up but no audio has arrived yet.
    /// (Bluetooth headsets can take a second or more here.)
    case startingMicrophone
    /// Audio is actually flowing from the microphone.
    case recording
    case transcribing
    case refining

    /// True while the hotkey is held / toggled on, whether or not audio has started flowing yet.
    var isCapturing: Bool {
        self == .startingMicrophone || self == .recording
    }
}

enum TranscriptionModel: String, CaseIterable {
    case whisperTinyEn = "whisper-tiny.en"
    case whisperBaseEn = "whisper-base.en"
    case whisperSmallEn = "whisper-small.en"
    case whisperLargeV3 = "whisper-large-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case parakeetV2 = "parakeet-v2"
    case parakeetV3 = "parakeet-v3"

    var displayName: String {
        switch self {
        case .whisperTinyEn: return "Whisper (tiny.en)"
        case .whisperBaseEn: return "Whisper (base.en)"
        case .whisperSmallEn: return "Whisper (small.en)"
        case .whisperLargeV3: return "Whisper (large-v3)"
        case .whisperLargeV3Turbo: return "Whisper (large-v3 turbo)"
        case .parakeetV2: return "Parakeet v2"
        case .parakeetV3: return "Parakeet v3"
        }
    }

    var description: String {
        switch self {
        case .whisperTinyEn: return "English only – smallest, ~75 MB"
        case .whisperBaseEn: return "English only – fast, ~140 MB"
        case .whisperSmallEn: return "English only – better accuracy, ~460 MB"
        case .whisperLargeV3: return "English + multilingual – best accuracy, ~3 GB"
        case .whisperLargeV3Turbo: return "English + multilingual – faster large model, ~954 MB"
        case .parakeetV2: return "English only – most accurate for English dictation"
        case .parakeetV3: return "25 languages – best for multilingual users"
        }
    }

    var estimatedSize: String {
        switch self {
        case .whisperTinyEn: return "~75 MB"
        case .whisperBaseEn: return "~140 MB"
        case .whisperSmallEn: return "~460 MB"
        case .whisperLargeV3: return "~3 GB"
        case .whisperLargeV3Turbo: return "~954 MB"
        case .parakeetV2: return "~600 MB"
        case .parakeetV3: return "~600 MB"
        }
    }

    /// True for multilingual Whisper models where a spoken language can be forced.
    /// Other models (English-only Whisper, Parakeet) transcribe automatically and
    /// cannot be constrained to a language via their engine's API.
    var supportsLanguageSelection: Bool {
        switch self {
        case .whisperLargeV3, .whisperLargeV3Turbo: return true
        default: return false
        }
    }

    /// WhisperKit variant string for download/load (nil for non-Whisper models).
    var whisperVariant: String? {
        switch self {
        case .whisperTinyEn: return "openai_whisper-tiny.en"
        case .whisperBaseEn: return "base.en"
        case .whisperSmallEn: return "small.en"
        case .whisperLargeV3: return "large-v3"
        case .whisperLargeV3Turbo: return "openai_whisper-large-v3_turbo_954MB"
        case .parakeetV2, .parakeetV3: return nil
        }
    }

    /// FluidAudio cache folder name for Parakeet models (nil for Whisper models).
    /// Matches `Repo.folderName` in FluidAudio so `isDownloaded` and deletion see the
    /// same directory the library downloads into.
    var parakeetFolderName: String? {
        switch self {
        case .parakeetV2: return "parakeet-tdt-0.6b-v2-coreml"
        case .parakeetV3: return "parakeet-tdt-0.6b-v3-coreml"
        default: return nil
        }
    }

    /// The base directory where models are stored (reads UserDefaults directly to avoid MainActor).
    private static var modelStorageBase: URL {
        if let path = UserDefaults.standard.string(forKey: "modelStorageLocation") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Speak2")
            .appendingPathComponent("Models")
    }

    /// The WhisperKit download directory within the model storage base.
    private static var whisperKitBase: URL {
        modelStorageBase
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
    }

    /// Path where this model's files are stored.
    /// Whisper: uses persisted path from WhisperKit.download if set, else default under Application Support.
    /// Parakeet: the per-version folder inside FluidAudio's cache, so each version can be
    /// downloaded and deleted independently.
    var storagePath: URL {
        switch self {
        case .whisperTinyEn, .whisperBaseEn, .whisperSmallEn, .whisperLargeV3, .whisperLargeV3Turbo:
            if let stored = Self.getStoredWhisperPath(for: self) {
                return stored
            }
            return Self.whisperKitBase.appendingPathComponent(whisperVariant ?? "unknown")
        case .parakeetV2, .parakeetV3:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FluidAudio")
                .appendingPathComponent("Models")
                .appendingPathComponent(parakeetFolderName!)
        }
    }

    /// Persist or clear the Whisper model folder path (set after download, cleared on delete).
    static func setStoredWhisperPath(_ url: URL?, for model: TranscriptionModel) {
        guard model.whisperVariant != nil else { return }
        let key = "whisperModelPath_\(model.rawValue)"
        if let url = url {
            UserDefaults.standard.set(url.path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func getStoredWhisperPath(for model: TranscriptionModel) -> URL? {
        guard let variant = model.whisperVariant else { return nil }
        if let path = UserDefaults.standard.string(forKey: "whisperModelPath_\(model.rawValue)") {
            return URL(fileURLWithPath: path)
        }
        // Migration: base.en was previously stored at Documents/huggingface; persist it so isDownloaded stays true
        if case .whisperBaseEn = model {
            let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface")
            if FileManager.default.fileExists(atPath: legacy.path),
               let contents = try? FileManager.default.contentsOfDirectory(atPath: legacy.path),
               !contents.isEmpty {
                setStoredWhisperPath(legacy, for: model)
                return legacy
            }
        }
        // Scan the WhisperKit download directory for this variant on disk
        let base = whisperKitBase
        if FileManager.default.fileExists(atPath: base.path),
           let folders = try? FileManager.default.contentsOfDirectory(atPath: base.path),
           let match = folders.first(where: { $0 == variant }) {
            let foundPath = base.appendingPathComponent(match)
            setStoredWhisperPath(foundPath, for: model)
            return foundPath
        }
        return nil
    }

    /// Check if this model is downloaded by looking for files on disk
    var isDownloaded: Bool {
        let path = storagePath
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        // Check if directory has content
        let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path)
        return (contents?.count ?? 0) > 0
    }

    static var saved: TranscriptionModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: "transcriptionModel"),
               let model = TranscriptionModel(rawValue: raw) {
                return model
            }
            return .whisperBaseEn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionModel")
        }
    }
}

// MARK: - Custom Hotkey Combo

struct CustomHotkeyCombo: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let triggerKeycode: Int64
    let triggerIsModifier: Bool
    /// CGEventFlags bitmask of modifiers that must be held (0 for modifier-only combos)
    let requiredModifierFlags: UInt64
    let displayName: String

    init(id: UUID = UUID(), triggerKeycode: Int64, triggerIsModifier: Bool, requiredModifierFlags: UInt64 = 0, displayName: String) {
        self.id = id
        self.triggerKeycode = triggerKeycode
        self.triggerIsModifier = triggerIsModifier
        self.requiredModifierFlags = requiredModifierFlags
        self.displayName = displayName
    }
}

enum HotkeyOption: String, CaseIterable {
    case fnKey = "fn"
    case rightOption = "rightOption"
    case rightCommand = "rightCommand"
    case hyperKey = "hyperKey"
    case ctrlOptionSpace = "ctrlOptionSpace"
    case custom = "custom"

    /// The key name without mode suffix (e.g. "Fn", "Right Option").
    var keyName: String {
        switch self {
        case .fnKey: return "Fn"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .hyperKey: return "Hyper Key – Ctrl+Opt+Cmd+Shift"
        case .ctrlOptionSpace: return "Ctrl+Option+Space"
        case .custom:
            return Self.activeCustomCombo?.displayName ?? "Custom Key"
        }
    }

    // MARK: - Custom combo UserDefaults storage

    static var savedCustomCombos: [CustomHotkeyCombo] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "customHotkeyCombos"),
                  let combos = try? JSONDecoder().decode([CustomHotkeyCombo].self, from: data) else {
                return []
            }
            return combos
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "customHotkeyCombos")
            }
        }
    }

    static var savedActiveCustomComboId: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "activeCustomComboId") else { return nil }
            return UUID(uuidString: str)
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(id.uuidString, forKey: "activeCustomComboId")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeCustomComboId")
            }
        }
    }

    static var activeCustomCombo: CustomHotkeyCombo? {
        guard let id = savedActiveCustomComboId else { return nil }
        return savedCustomCombos.first { $0.id == id }
    }

    /// Display name including the current mode suffix.
    var displayName: String {
        let suffix = Self.isToggleMode ? "(press twice)" : "(hold)"
        return "\(keyName) \(suffix)"
    }

    /// Whether the hotkey operates in toggle (press-twice) mode vs hold mode.
    static var isToggleMode: Bool {
        get { UserDefaults.standard.bool(forKey: "hotkeyToggleMode") }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeyToggleMode") }
    }

    static var saved: HotkeyOption {
        get {
            if let raw = UserDefaults.standard.string(forKey: "hotkeyOption") {
                // Migration: doubleTapControl → fnKey + toggle mode
                if raw == "doubleTapControl" {
                    isToggleMode = true
                    let migrated = HotkeyOption.fnKey
                    UserDefaults.standard.set(migrated.rawValue, forKey: "hotkeyOption")
                    return migrated
                }
                if let option = HotkeyOption(rawValue: raw) {
                    return option
                }
            }
            return .fnKey
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "hotkeyOption")
        }
    }

    /// Migrate old single-key custom hotkey to the new combo list format.
    static func migrateCustomHotkeyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didMigrateCustomHotkeyToCombo") else { return }
        UserDefaults.standard.set(true, forKey: "didMigrateCustomHotkeyToCombo")

        // Read old keys
        guard UserDefaults.standard.object(forKey: "customHotkeyKeycode") != nil else { return }
        let keycode = Int64(UserDefaults.standard.integer(forKey: "customHotkeyKeycode"))
        let isModifier = UserDefaults.standard.bool(forKey: "customHotkeyIsModifier")
        let name = UserDefaults.standard.string(forKey: "customHotkeyName") ?? ""
        guard !name.isEmpty else { return }

        let combo = CustomHotkeyCombo(
            triggerKeycode: keycode,
            triggerIsModifier: isModifier,
            requiredModifierFlags: 0,
            displayName: name
        )

        var combos = savedCustomCombos
        combos.append(combo)
        savedCustomCombos = combos
        savedActiveCustomComboId = combo.id

        // Clean up old keys
        UserDefaults.standard.removeObject(forKey: "customHotkeyKeycode")
        UserDefaults.standard.removeObject(forKey: "customHotkeyIsModifier")
        UserDefaults.standard.removeObject(forKey: "customHotkeyName")
    }
}

enum RefinementMode: String, CaseIterable {
    case off
    case builtIn
    case external

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .builtIn: return "Built-in (recommended)"
        case .external: return "External Server (Ollama)"
        }
    }

    static var saved: RefinementMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: "refinementMode"),
               let mode = RefinementMode(rawValue: raw) {
                return mode
            }
            // Migration: if legacy ollamaEnabled is true and no refinementMode key exists
            if UserDefaults.standard.object(forKey: "refinementMode") == nil,
               UserDefaults.standard.bool(forKey: "ollamaEnabled") {
                let migrated = RefinementMode.external
                UserDefaults.standard.set(migrated.rawValue, forKey: "refinementMode")
                return migrated
            }
            return .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "refinementMode")
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    static let appVersion = "1.10.0"

    @Published var recordingState: RecordingState = .idle
    @Published var isModelLoaded: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var hasMicrophonePermission: Bool = false
    @Published var modelDownloadProgress: Double = 0.0
    @Published var lastError: String? = nil
    @Published var isLLMModelDownloading: Bool = false
    @Published var llmDownloadProgress: Double = 0.0

    // Model selection
    @Published var selectedModel: TranscriptionModel = TranscriptionModel.saved
    @Published var currentlyLoadedModel: TranscriptionModel? = nil
    @Published var downloadedModels: Set<TranscriptionModel> = []
    
    // Model storage location preference
    static var defaultModelStorageLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Speak2")
            .appendingPathComponent("Models")
    }

    static var modelStorageLocation: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "modelStorageLocation") {
                return URL(fileURLWithPath: path)
            }
            return defaultModelStorageLocation
        }
        set {
            let currentPath = UserDefaults.standard.string(forKey: "modelStorageLocation")
            guard currentPath != newValue.path else { return }
            UserDefaults.standard.set(newValue.path, forKey: "modelStorageLocation")
            // Clear all stored model paths since they point to the old location
            for model in TranscriptionModel.allCases {
                TranscriptionModel.setStoredWhisperPath(nil, for: model)
            }
        }
    }

    // Personal dictionary
    let dictionaryState = DictionaryState()

    // Transcription history
    let historyState = TranscriptionHistoryState()

    // Microphone selection (nil = System Default). Mirrors AudioInputPreference so views can observe it.
    @Published var preferredInputDeviceUID: String? = AudioInputPreference.savedUID {
        didSet {
            if AudioInputPreference.savedUID != preferredInputDeviceUID {
                AudioInputPreference.savedUID = preferredInputDeviceUID
            }
        }
    }

    // Live transcription
    @Published var liveTranscriptionEnabled: Bool = UserDefaults.standard.bool(forKey: "liveTranscriptionEnabled") {
        didSet {
            UserDefaults.standard.set(liveTranscriptionEnabled, forKey: "liveTranscriptionEnabled")
        }
    }
    @Published var liveTranscriptionConfirmedText: String = ""
    @Published var liveTranscriptionUnconfirmedText: String = ""

    private init() {
        // Migrate legacy models from ~/Documents/huggingface if needed
        Self.migrateModelsFromLegacyLocationIfNeeded()
        // Migrate old single-key custom hotkey to combo list
        HotkeyOption.migrateCustomHotkeyIfNeeded()

        refreshDownloadedModels()
        dictionaryState.load()
        historyState.load()
    }

    /// One-time migration from legacy ~/Documents/huggingface to new Application Support location
    private static func migrateModelsFromLegacyLocationIfNeeded() {
        // Only migrate if user hasn't set a custom location
        guard UserDefaults.standard.string(forKey: "modelStorageLocation") == nil else { return }

        // Check if we've already attempted migration
        guard !UserDefaults.standard.bool(forKey: "didAttemptLegacyMigrationV2") else { return }
        UserDefaults.standard.set(true, forKey: "didAttemptLegacyMigrationV2")

        let legacyLocation = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface")

        // Check if legacy location has WhisperKit models (actual structure: models/argmaxinc/whisperkit-coreml/)
        let legacyModelsPath = legacyLocation
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")

        guard FileManager.default.fileExists(atPath: legacyModelsPath.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: legacyModelsPath.path),
              contents.contains(where: { $0.contains("whisper") }) else {
            return
        }

        // Found legacy models - migrate them
        let newLocation = defaultModelStorageLocation
        // Match WhisperKit's internal path structure (no "huggingface" prefix)
        let newModelsPath = newLocation
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")

        do {
            // Create destination directory
            try FileManager.default.createDirectory(at: newModelsPath, withIntermediateDirectories: true)

            // Move each model folder (e.g., openai_whisper-base.en)
            for item in contents {
                // Skip hidden files and cache
                guard !item.hasPrefix(".") else { continue }

                let sourcePath = legacyModelsPath.appendingPathComponent(item)
                let destPath = newModelsPath.appendingPathComponent(item)

                // Check if it's a directory (model folder)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourcePath.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                if !FileManager.default.fileExists(atPath: destPath.path) {
                    try FileManager.default.moveItem(at: sourcePath, to: destPath)
                    print("Migrated model: \(item)")
                }
            }

            // Update stored paths for known models
            updateStoredPathsAfterMigration(newModelsPath: newModelsPath)

            print("Successfully migrated Whisper models to \(newLocation.path)")
        } catch {
            print("Failed to migrate legacy models: \(error)")
        }
    }

    /// Update stored model paths after migration
    private static func updateStoredPathsAfterMigration(newModelsPath: URL) {
        // Scan the new location for model folders and update stored paths
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: newModelsPath.path) else { return }

        for folder in folders {
            // Skip hidden files
            guard !folder.hasPrefix(".") else { continue }

            let modelPath = newModelsPath.appendingPathComponent(folder)

            // Match folder name to model
            for model in TranscriptionModel.allCases {
                if folderMatchesModel(folder, model: model) {
                    TranscriptionModel.setStoredWhisperPath(modelPath, for: model)
                    print("Registered model path for \(model.displayName): \(modelPath.path)")
                }
            }
        }
    }

    /// Helper to match folder names to models (handles WhisperKit naming conventions)
    private static func folderMatchesModel(_ folder: String, model: TranscriptionModel) -> Bool {
        let folderLower = folder.lowercased()
        switch model {
        case .whisperTinyEn:
            return folderLower.contains("tiny") && folderLower.contains("en")
        case .whisperBaseEn:
            return folderLower.contains("base") && folderLower.contains("en") && !folderLower.contains("large")
        case .whisperSmallEn:
            return folderLower.contains("small") && folderLower.contains("en")
        case .whisperLargeV3:
            return folderLower.contains("large-v3") && !folderLower.contains("turbo")
        case .whisperLargeV3Turbo:
            return folderLower.contains("large") && folderLower.contains("turbo")
        case .parakeetV2, .parakeetV3:
            return false
        }
    }

    var isSetupComplete: Bool {
        isModelLoaded && hasAccessibilityPermission && hasMicrophonePermission
    }

    /// Refresh the set of downloaded models by checking filesystem
    func refreshDownloadedModels() {
        downloadedModels = Set(TranscriptionModel.allCases.filter { $0.isDownloaded })
    }
}
