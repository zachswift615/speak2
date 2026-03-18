import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var downloadingModel: TranscriptionModel? = nil
    @State private var isWhisperExpanded = true
    @State private var showLargeDownloadAlert = false
    @State private var pendingLargeDownload: TranscriptionModel? = nil
    var modelManager: ModelManager?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Models Section
                SettingsSection(title: "Speech Recognition Models") {
                    VStack(spacing: 0) {
                        // Whisper section with disclosure
                        ModelGroupSection(
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

                        // Parakeet row
                        ModelSettingsRow(
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
                }

                // Storage Location Section
                SettingsSection(title: "Storage Location") {
                    ModelStorageSettingsRow(appState: appState)
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            appState.refreshDownloadedModels()

            // Auto-load the selected model if it's downloaded but not loaded
            if appState.downloadedModels.contains(appState.selectedModel) && !appState.isModelLoaded {
                downloadModel(appState.selectedModel)
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

// MARK: - Model Group Section (Whisper)

struct ModelGroupSection: View {
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
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)

                    Image(systemName: isAnyWhisperSelected ? "circle.inset.filled" : "circle")
                        .foregroundColor(isAnyWhisperSelected ? .accentColor : .secondary)
                        .font(.body)

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
                                ModelActiveBadge()
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

                    if !isExpanded {
                        ModelStatusIndicator(
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

                        WhisperVariantSettingsRow(
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

// MARK: - Whisper Variant Row

struct WhisperVariantSettingsRow: View {
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
            Color.clear.frame(width: 16)

            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.variantName)
                        .fontWeight(.medium)
                    if isCurrentlyLoaded {
                        ModelActiveBadge()
                    }
                }
                Text(model.variantDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ModelStatusIndicator(
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

// MARK: - Model Settings Row (for Parakeet)

struct ModelSettingsRow: View {
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
            Color.clear.frame(width: 16)

            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    if isCurrentlyLoaded {
                        ModelActiveBadge()
                    }
                }
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ModelStatusIndicator(
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

// MARK: - Model Status Indicator

struct ModelStatusIndicator: View {
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

// MARK: - Model Active Badge

struct ModelActiveBadge: View {
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

// MARK: - Model Storage Settings Row

struct ModelStorageSettingsRow: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Location")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(storageLocation.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isMovingModels {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Moving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
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
            }
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
        guard newLocation.standardizedFileURL != storageLocation.standardizedFileURL else { return }
        if downloadedModelsAtCurrentLocation.isEmpty {
            changeLocationWithoutMoving(newLocation)
            return
        }
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

                let newModelPath = newLocation
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("whisperkit-coreml")

                do {
                    try FileManager.default.createDirectory(at: newModelPath, withIntermediateDirectories: true)

                    if FileManager.default.fileExists(atPath: currentPath.path) {
                        let destPath = newModelPath.appendingPathComponent(currentPath.lastPathComponent)

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
                AppState.modelStorageLocation = newLocation
                storageLocation = newLocation

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
