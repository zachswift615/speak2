import SwiftUI
import AVFoundation

struct SetupView: View {
    @ObservedObject var appState = AppState.shared
    @State private var downloadingModel: TranscriptionModel? = nil
    @State private var isWhisperExpanded = false
    @State private var showLargeDownloadAlert = false
    @State private var pendingLargeDownload: TranscriptionModel? = nil
    var modelManager: ModelManager?

    private var selectedWhisperModel: TranscriptionModel {
        if let selected = appState.selectedModel.whisperVariant != nil ? appState.selectedModel : nil {
            return selected
        }
        return .whisperBaseEn
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Speak2 Setup")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Grant permissions and download a speech model to get started.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required for global hotkey detection",
                    isGranted: appState.hasAccessibilityPermission,
                    action: requestAccessibility
                )

                PermissionRow(
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: appState.hasMicrophonePermission,
                    action: requestMicrophone
                )

                Divider()
                    .padding(.vertical, 4)

                Text("Speech Recognition Model")
                    .fontWeight(.medium)

                // Model table
                VStack(spacing: 0) {
                    // Whisper section with disclosure
                    WhisperModelSection(
                        isExpanded: $isWhisperExpanded,
                        selectedModel: appState.selectedModel,
                        downloadingModel: downloadingModel,
                        downloadedModels: appState.downloadedModels,
                        currentlyLoadedModel: appState.currentlyLoadedModel,
                        progress: appState.modelDownloadProgress,
                        onSelect: selectModel,
                        onDownload: confirmAndDownload,
                        onDelete: deleteModel
                    )

                    Divider()
                        .padding(.leading, 32)

                    // Parakeet rows
                    ModelRow(
                        model: .parakeetV2,
                        isSelected: appState.selectedModel == .parakeetV2,
                        isDownloaded: appState.downloadedModels.contains(.parakeetV2),
                        isDownloading: downloadingModel == .parakeetV2,
                        isCurrentlyLoaded: appState.currentlyLoadedModel == .parakeetV2,
                        progress: downloadingModel == .parakeetV2 ? appState.modelDownloadProgress : 0,
                        onSelect: { selectModel(.parakeetV2) },
                        onDownload: { confirmAndDownload(.parakeetV2) },
                        onDelete: { deleteModel(.parakeetV2) }
                    )

                    Divider()
                        .padding(.leading, 32)

                    ModelRow(
                        model: .parakeetV3,
                        isSelected: appState.selectedModel == .parakeetV3,
                        isDownloaded: appState.downloadedModels.contains(.parakeetV3),
                        isDownloading: downloadingModel == .parakeetV3,
                        isCurrentlyLoaded: appState.currentlyLoadedModel == .parakeetV3,
                        progress: downloadingModel == .parakeetV3 ? appState.modelDownloadProgress : 0,
                        onSelect: { selectModel(.parakeetV3) },
                        onDownload: { confirmAndDownload(.parakeetV3) },
                        onDelete: { deleteModel(.parakeetV3) }
                    )
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(8)

                Divider()
                    .padding(.vertical, 4)

                ModelStorageLocationRow(appState: appState)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            if appState.isSetupComplete {
                Text("Setup complete! Speak2 is ready.")
                    .foregroundColor(.green)
                    .fontWeight(.medium)

                Button("Close") {
                    NSApplication.shared.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Download Large Model?", isPresented: $showLargeDownloadAlert) {
            Button("Download") {
                if let model = pendingLargeDownload {
                    downloadModel(model)
                }
                pendingLargeDownload = nil
            }
            Button("Cancel", role: .cancel) {
                pendingLargeDownload = nil
            }
        } message: {
            if let model = pendingLargeDownload {
                Text("\(model.displayName) is \(model.estimatedSize). This may take a while to download and requires significant disk space.")
            }
        }
        .onAppear {
            checkPermissions()
            appState.refreshDownloadedModels()

            // Auto-load the selected model if it's downloaded but not loaded
            // (e.g., after migration or app restart)
            if appState.downloadedModels.contains(appState.selectedModel) && !appState.isModelLoaded {
                downloadModel(appState.selectedModel)
            }
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
                appState.hasAccessibilityPermission = true
                timer.invalidate()
            }
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                appState.hasMicrophonePermission = granted
            }
        }
    }

    private func selectModel(_ model: TranscriptionModel) {
        appState.selectedModel = model
        TranscriptionModel.saved = model

        if appState.downloadedModels.contains(model) {
            downloadModel(model)
        }
    }

    private func confirmAndDownload(_ model: TranscriptionModel) {
        // Confirm large downloads
        if model == .whisperLargeV3 || model == .whisperLargeV3Turbo {
            pendingLargeDownload = model
            showLargeDownloadAlert = true
        } else {
            downloadModel(model)
        }
    }

    private func downloadModel(_ model: TranscriptionModel) {
        guard let modelManager = modelManager else { return }
        downloadingModel = model

        Task {
            do {
                try await modelManager.loadModel(model) { progress in
                    Task { @MainActor in
                        appState.modelDownloadProgress = progress
                    }
                }
                await MainActor.run {
                    downloadingModel = nil
                }
            } catch {
                await MainActor.run {
                    appState.lastError = error.localizedDescription
                    downloadingModel = nil
                }
            }
        }
    }

    private func deleteModel(_ model: TranscriptionModel) {
        guard let modelManager = modelManager else { return }

        Task {
            do {
                try await modelManager.deleteModel(model)
            } catch {
                await MainActor.run {
                    appState.lastError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Whisper Model Section

struct WhisperModelSection: View {
    @Binding var isExpanded: Bool
    let selectedModel: TranscriptionModel
    let downloadingModel: TranscriptionModel?
    let downloadedModels: Set<TranscriptionModel>
    let currentlyLoadedModel: TranscriptionModel?
    let progress: Double
    let onSelect: (TranscriptionModel) -> Void
    let onDownload: (TranscriptionModel) -> Void
    let onDelete: (TranscriptionModel) -> Void

    private static let whisperModels: [TranscriptionModel] = [
        .whisperTinyEn, .whisperBaseEn, .whisperSmallEn, .whisperLargeV3, .whisperLargeV3Turbo
    ]

    private var isAnyWhisperSelected: Bool {
        selectedModel.whisperVariant != nil
    }

    private var activeWhisperModel: TranscriptionModel {
        if selectedModel.whisperVariant != nil {
            return selectedModel
        }
        return .whisperBaseEn
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main Whisper row (collapsed view)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Disclosure chevron
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)

                    // Radio button
                    Image(systemName: isAnyWhisperSelected ? "circle.inset.filled" : "circle")
                        .foregroundColor(isAnyWhisperSelected ? .accentColor : .secondary)
                        .font(.body)

                    // Name
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Whisper")
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            if !isExpanded && isAnyWhisperSelected {
                                Text(activeWhisperModel.variantName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if currentlyLoadedModel?.whisperVariant != nil {
                                ActiveBadge()
                            }
                        }
                        HStack(spacing: 4) {
                            Text("OpenAI's speech recognition")
                            if !isExpanded {
                                Text("·")
                                Text("5 sizes available")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Status column (only show when collapsed)
                    if !isExpanded {
                        ModelStatusView(
                            model: activeWhisperModel,
                            isDownloaded: downloadedModels.contains(activeWhisperModel),
                            isDownloading: downloadingModel == activeWhisperModel,
                            progress: downloadingModel == activeWhisperModel ? progress : 0,
                            onDownload: { onDownload(activeWhisperModel) },
                            onDelete: { onDelete(activeWhisperModel) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded Whisper variants
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Self.whisperModels, id: \.self) { model in
                        Divider()
                            .padding(.leading, 56)

                        WhisperVariantRow(
                            model: model,
                            isSelected: selectedModel == model,
                            isDownloaded: downloadedModels.contains(model),
                            isDownloading: downloadingModel == model,
                            isCurrentlyLoaded: currentlyLoadedModel == model,
                            progress: downloadingModel == model ? progress : 0,
                            onSelect: { onSelect(model) },
                            onDownload: { onDownload(model) },
                            onDelete: { onDelete(model) }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Whisper Variant Row (indented)

struct WhisperVariantRow: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let isCurrentlyLoaded: Bool
    let progress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Indent spacer
            Color.clear.frame(width: 16)

            // Radio button
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.variantName)
                        .fontWeight(.medium)
                    if isCurrentlyLoaded {
                        ActiveBadge()
                    }
                }
                Text(model.variantDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status
            ModelStatusView(
                model: model,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                progress: progress,
                onDownload: onDownload,
                onDelete: onDelete
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded && !isDownloading {
                onSelect()
            } else if !isDownloaded && !isDownloading {
                onDownload()
            }
        }
    }
}

// MARK: - Model Row (for Parakeet)

struct ModelRow: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let isCurrentlyLoaded: Bool
    let progress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Spacer to align with Whisper rows
            Color.clear.frame(width: 16)

            // Radio button
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    if isCurrentlyLoaded {
                        ActiveBadge()
                    }
                }
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status
            ModelStatusView(
                model: model,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                progress: progress,
                onDownload: onDownload,
                onDelete: onDelete
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded && !isDownloading {
                onSelect()
            } else if !isDownloaded && !isDownloading {
                onDownload()
            }
        }
    }
}

// MARK: - Model Status View (download/size/delete column)

struct ModelStatusView: View {
    let model: TranscriptionModel
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isDownloading {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(progress >= 0.99 ? "Loading..." : "Downloading...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(width: 70)
                }
                .frame(width: 100, alignment: .trailing)
            } else if isDownloaded {
                Text(model.estimatedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Delete model")
            } else {
                Button("Download") {
                    onDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(model.estimatedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}

// MARK: - Active Badge

struct ActiveBadge: View {
    var body: some View {
        Text("Active")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.2))
            .foregroundColor(.green)
            .cornerRadius(4)
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
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
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Model Storage Location Row

struct ModelStorageLocationRow: View {
    @ObservedObject var appState: AppState
    @State private var storageLocation: URL = AppState.modelStorageLocation
    @State private var pendingNewLocation: URL? = nil
    @State private var showMoveModelsAlert = false
    @State private var isMovingModels = false

    private var isDefaultLocation: Bool {
        storageLocation.path == AppState.defaultModelStorageLocation.path
    }

    private var downloadedModelsAtCurrentLocation: [TranscriptionModel] {
        TranscriptionModel.allCases.filter { model in
            guard model.whisperVariant != nil else { return false }
            return appState.downloadedModels.contains(model)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Storage Location")
                        .fontWeight(.medium)
                    Text("Where downloaded models are stored")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isMovingModels {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Moving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if !isDefaultLocation {
                        Button("Use Default") {
                            confirmLocationChange(to: AppState.defaultModelStorageLocation)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button("Choose Folder...") {
                        chooseFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(storageLocation.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear {
            storageLocation = AppState.modelStorageLocation
        }
        .alert("Move Downloaded Models?", isPresented: $showMoveModelsAlert) {
            Button("Move Models") {
                if let newLocation = pendingNewLocation {
                    moveModelsToNewLocation(newLocation)
                }
            }
            Button("Start Fresh") {
                if let newLocation = pendingNewLocation {
                    changeLocationWithoutMoving(newLocation)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingNewLocation = nil
            }
        } message: {
            let count = downloadedModelsAtCurrentLocation.count
            let modelText = count == 1 ? "1 model" : "\(count) models"
            Text("You have \(modelText) downloaded at the current location. Would you like to move them to the new location, or start fresh?\n\nStarting fresh will leave the old files on disk.")
        }
    }

    private func confirmLocationChange(to newLocation: URL) {
        // If no models downloaded, just change location
        if downloadedModelsAtCurrentLocation.isEmpty {
            changeLocationWithoutMoving(newLocation)
            return
        }

        // Otherwise, ask user what to do
        pendingNewLocation = newLocation
        showMoveModelsAlert = true
    }

    private func changeLocationWithoutMoving(_ newLocation: URL) {
        storageLocation = newLocation
        AppState.modelStorageLocation = newLocation
        appState.refreshDownloadedModels()
        pendingNewLocation = nil
    }

    private func moveModelsToNewLocation(_ newLocation: URL) {
        isMovingModels = true
        let modelsToMove = downloadedModelsAtCurrentLocation

        Task {
            var movedPaths: [(TranscriptionModel, URL)] = []

            for model in modelsToMove {
                guard let currentPath = TranscriptionModel.getStoredWhisperPath(for: model),
                      model.whisperVariant != nil else { continue }

                // Match WhisperKit's internal path structure
                let newModelPath = newLocation
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("whisperkit-coreml")

                do {
                    // Create destination directory
                    try FileManager.default.createDirectory(at: newModelPath, withIntermediateDirectories: true)

                    if FileManager.default.fileExists(atPath: currentPath.path) {
                        let destPath = newModelPath
                            .appendingPathComponent(currentPath.lastPathComponent)

                        // Move the model folder
                        if !FileManager.default.fileExists(atPath: destPath.path) {
                            try FileManager.default.moveItem(at: currentPath, to: destPath)
                        }
                        movedPaths.append((model, destPath))
                    }
                } catch {
                    print("Failed to move \(model.displayName): \(error)")
                }
            }

            await MainActor.run {
                // Update storage location
                AppState.modelStorageLocation = newLocation
                storageLocation = newLocation

                // Update stored paths for moved models
                for (model, newPath) in movedPaths {
                    TranscriptionModel.setStoredWhisperPath(newPath, for: model)
                }

                appState.refreshDownloadedModels()
                isMovingModels = false
                pendingNewLocation = nil
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to store downloaded models"
        panel.directoryURL = storageLocation

        panel.begin { response in
            if response == .OK, let url = panel.url {
                confirmLocationChange(to: url)
            }
        }
    }
}

// MARK: - TranscriptionModel Extensions

extension TranscriptionModel {
    /// Short variant name for Whisper models (e.g., "base.en", "large-v3")
    var variantName: String {
        switch self {
        case .whisperTinyEn: return "tiny.en"
        case .whisperBaseEn: return "base.en"
        case .whisperSmallEn: return "small.en"
        case .whisperLargeV3: return "large-v3"
        case .whisperLargeV3Turbo: return "large-v3 turbo"
        case .parakeetV2: return "v2"
        case .parakeetV3: return "v3"
        }
    }

    /// Short description for Whisper variants
    var variantDescription: String {
        switch self {
        case .whisperTinyEn: return "Smallest, fastest"
        case .whisperBaseEn: return "Recommended balance"
        case .whisperSmallEn: return "Better accuracy"
        case .whisperLargeV3: return "Best accuracy, multilingual"
        case .whisperLargeV3Turbo: return "Fast + accurate, multilingual"
        case .parakeetV2, .parakeetV3: return description
        }
    }
}
