import SwiftUI

struct AIRefineSettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var refinementMode: RefinementMode = RefinementMode.saved

    @AppStorage("ollamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel: String = "gemma3:4b"
    @AppStorage("ollamaPrompt") private var ollamaPrompt: String = ""
    @AppStorage("externalAPIFormat") private var apiFormat: ExternalAPIFormat = .ollama
    @AppStorage("openAIBaseURL") private var openAIBaseURL: String = ""
    @AppStorage("openAIModel") private var openAIModel: String = ""
    @State private var apiKey: String = KeychainStore.string(for: ExternalRefiner.apiKeyAccount) ?? ""

    @AppStorage(MLXRefiner.exampleUser1Key) private var exampleUser1: String = ""
    @AppStorage(MLXRefiner.exampleAssistant1Key) private var exampleAssistant1: String = ""
    @AppStorage(MLXRefiner.exampleUser2Key) private var exampleUser2: String = ""
    @AppStorage(MLXRefiner.exampleAssistant2Key) private var exampleAssistant2: String = ""

    @State private var testStatus: TestStatus = .idle
    @State private var isModelCached: Bool = MLXRefiner.isModelCached
    @State private var showAdvancedExamples: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Language notice for non-English users
                if refinementMode != .off {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "globe")
                            .foregroundStyle(Color.accentColor)
                            .font(.body)
                        Text("**Non-English dictation:** the default Refinement Prompt and the few-shot examples under Advanced are in English, which biases the model toward English output. For reliable refinement in another language, translate both the Refinement Prompt and the example pairs into that language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                // Mode picker
                SettingsSection(title: "AI Text Refinement") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("After transcription, the text is sent to an LLM which removes filler words, false starts, and verbal noise before pasting the result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Mode", selection: $refinementMode) {
                            ForEach(RefinementMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: refinementMode) { _, newValue in
                            RefinementMode.saved = newValue
                        }
                    }
                }

                // Built-in model section
                if refinementMode == .builtIn {
                    SettingsSection(title: "Built-in Model") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Qwen 2.5 1.5B Instruct")
                                        .fontWeight(.medium)
                                    Text("~1.1 GB download")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                modelStatusView
                            }

                            if appState.isLLMModelDownloading {
                                ProgressView(value: appState.llmDownloadProgress)
                                    .progressViewStyle(.linear)
                            }
                        }
                    }
                }

                // External server section
                if refinementMode == .external {
                    SettingsSection(title: "External Server") {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Format")
                                    .fontWeight(.medium)
                                Picker("API Format", selection: $apiFormat) {
                                    ForEach(ExternalAPIFormat.allCases, id: \.self) { format in
                                        Text(format.displayName).tag(format)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                .onChange(of: apiFormat) { _, _ in
                                    testStatus = .idle
                                }
                                if apiFormat == .openAICompatible {
                                    Text("For LiteLLM, LM Studio, vLLM, llama.cpp, OpenAI, OpenRouter, and other servers with a /v1/chat/completions endpoint.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server URL")
                                    .fontWeight(.medium)
                                TextField(apiFormat == .ollama ? "http://localhost:11434" : "http://localhost:4000/v1", text: serverURL)
                                    .textFieldStyle(.roundedBorder)
                                if let host = ExternalRefiner.remoteHost(for: serverURL.wrappedValue) {
                                    Label("Dictated text will be sent to \(host).", systemImage: "network")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model Name")
                                    .fontWeight(.medium)
                                TextField(apiFormat == .ollama ? "gemma3:4b" : "gpt-4o-mini", text: modelName)
                                    .textFieldStyle(.roundedBorder)
                                Text(apiFormat == .ollama
                                     ? "The model must already be pulled in Ollama (e.g. ollama pull gemma3:4b)"
                                     : "The model name exactly as your server lists it")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if apiFormat == .openAICompatible {
                                Divider()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("API Key")
                                        .fontWeight(.medium)
                                    SecureField("Optional for local servers", text: $apiKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: apiKey) { _, newValue in
                                            KeychainStore.set(newValue, for: ExternalRefiner.apiKeyAccount)
                                        }
                                    Text("Stored in your Keychain")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            HStack(spacing: 10) {
                                Button("Test Connection") {
                                    testConnection()
                                }
                                .disabled(!externalRefiner.isConfigured)

                                testStatusLabel
                            }
                        }
                    }
                }

                // Prompt customisation (shared for both built-in and external)
                if refinementMode != .off {
                    SettingsSection(title: "Refinement Prompt") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The prompt is prepended to your transcription before it is sent to the model. Leave empty to use the built-in default.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $ollamaPrompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                                .overlay(alignment: .topLeading) {
                                    if ollamaPrompt.isEmpty {
                                        Text(OllamaRefiner.defaultPrompt)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary.opacity(0.5))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                }

                            if !ollamaPrompt.isEmpty {
                                Button("Reset to Default") {
                                    ollamaPrompt = ""
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                // Advanced: editable few-shot examples (built-in model only)
                if refinementMode == .builtIn {
                    SettingsSection(title: "Advanced") {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup(isExpanded: $showAdvancedExamples) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("These example pairs teach the built-in model the cleanup style (raw transcription → cleaned version). They are sent on every refinement request, so they strongly influence the output language. If you dictate in a language other than English, replace them with equivalents in your language — otherwise the model tends to translate its output to English.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    examplePair(
                                        index: 1,
                                        userText: $exampleUser1,
                                        assistantText: $exampleAssistant1,
                                        userPlaceholder: MLXRefiner.defaultExampleUser1,
                                        assistantPlaceholder: MLXRefiner.defaultExampleAssistant1
                                    )

                                    Divider()

                                    examplePair(
                                        index: 2,
                                        userText: $exampleUser2,
                                        assistantText: $exampleAssistant2,
                                        userPlaceholder: MLXRefiner.defaultExampleUser2,
                                        assistantPlaceholder: MLXRefiner.defaultExampleAssistant2
                                    )

                                    if !allExamplesAtDefaults {
                                        Button("Reset Examples to Defaults") {
                                            exampleUser1 = ""
                                            exampleAssistant1 = ""
                                            exampleUser2 = ""
                                            exampleAssistant2 = ""
                                        }
                                        .font(.caption)
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text("Few-shot examples")
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var allExamplesAtDefaults: Bool {
        exampleUser1.isEmpty && exampleAssistant1.isEmpty &&
        exampleUser2.isEmpty && exampleAssistant2.isEmpty
    }

    @ViewBuilder
    private func examplePair(
        index: Int,
        userText: Binding<String>,
        assistantText: Binding<String>,
        userPlaceholder: String,
        assistantPlaceholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Example \(index)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Raw (user)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                placeholderTextField(text: userText, placeholder: userPlaceholder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Cleaned (assistant)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                placeholderTextField(text: assistantText, placeholder: assistantPlaceholder)
            }
        }
    }

    @ViewBuilder
    private func placeholderTextField(text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.secondary.opacity(0.6)), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
    }

    @ViewBuilder
    private var modelStatusView: some View {
        if appState.isLLMModelDownloading {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if isModelCached {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Button("Download Model") {
                downloadModel()
            }
            .buttonStyle(.bordered)
        }
    }

    private func downloadModel() {
        appState.isLLMModelDownloading = true
        appState.llmDownloadProgress = 0

        Task {
            do {
                let refiner = MLXRefiner()
                try await refiner.loadModel { progress in
                    Task { @MainActor in
                        appState.llmDownloadProgress = progress
                    }
                }
                await MainActor.run {
                    appState.isLLMModelDownloading = false
                    isModelCached = true
                }
            } catch {
                await MainActor.run {
                    appState.isLLMModelDownloading = false
                    appState.lastError = "LLM download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @ViewBuilder
    private var testStatusLabel: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var serverURL: Binding<String> {
        apiFormat == .ollama ? $ollamaURL : $openAIBaseURL
    }

    private var modelName: Binding<String> {
        apiFormat == .ollama ? $ollamaModel : $openAIModel
    }

    private var externalRefiner: ExternalRefiner {
        ExternalRefiner(
            format: apiFormat,
            baseURL: serverURL.wrappedValue,
            model: modelName.wrappedValue,
            apiKey: apiFormat == .openAICompatible ? apiKey : nil
        )
    }

    private func testConnection() {
        testStatus = .testing
        let refiner = externalRefiner
        Task {
            do {
                _ = try await refiner.refine(text: "hello world")
                await MainActor.run {
                    testStatus = .success("Connected — got response")
                }
            } catch {
                await MainActor.run {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }
}

private enum TestStatus {
    case idle
    case testing
    case success(String)
    case failure(String)
}
