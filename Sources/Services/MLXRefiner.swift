import Foundation
import MLXLLM
import MLXLMCommon
import MLX

actor MLXRefiner {
    static let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    // MARK: - Few-shot examples

    /// Default English few-shot pairs that teach the model the cleanup style.
    /// These can be overridden per-user via the keys below. Non-English users
    /// should replace these with equivalents in their language, otherwise the
    /// model tends to translate its output to English.
    static let defaultExampleUser1 = "um so like should I should I start with the model or the view first?"
    static let defaultExampleAssistant1 = "Should I start with the model or the view first?"
    static let defaultExampleUser2 = "hey uh good morning I was just wondering if you could you know take a look at the pull request when you get a chance"
    static let defaultExampleAssistant2 = "Hey, good morning. I was just wondering if you could take a look at the pull request when you get a chance."

    static let exampleUser1Key = "refineExampleUser1"
    static let exampleAssistant1Key = "refineExampleAssistant1"
    static let exampleUser2Key = "refineExampleUser2"
    static let exampleAssistant2Key = "refineExampleAssistant2"

    /// Read a stored example from UserDefaults, returning the default if blank/missing.
    private static func storedExample(forKey key: String, default defaultValue: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : raw
    }

    /// HF Hub cache path used to check if the model is already downloaded.
    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/huggingface/hub")
            .appendingPathComponent("models--mlx-community--Qwen2.5-1.5B-Instruct-4bit")
    }

    static var isModelCached: Bool {
        let path = cacheURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: path)
        return (contents?.count ?? 0) > 0
    }

    private var modelContainer: ModelContainer?

    var isModelLoaded: Bool {
        modelContainer != nil
    }

    func loadModel(progressHandler: @Sendable @escaping (Double) -> Void) async throws {
        guard modelContainer == nil else { return }

        let configuration = ModelConfiguration(id: Self.modelID)

        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }

        self.modelContainer = container
    }

    func unloadModel() {
        modelContainer = nil
        MLX.GPU.clearCache()
    }

    func refine(text: String, customPrompt: String? = nil, languageName: String? = nil) async throws -> String {
        guard let container = modelContainer else {
            throw MLXRefinerError.modelNotLoaded
        }

        let basePrompt = customPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? OllamaRefiner.defaultPrompt
        let systemPrompt = basePrompt + OllamaRefiner.languageDirective(for: languageName)

        let parameters = GenerateParameters(
            maxTokens: 512,
            temperature: 0.1
        )

        let exampleUser1 = Self.storedExample(forKey: Self.exampleUser1Key, default: Self.defaultExampleUser1)
        let exampleAssistant1 = Self.storedExample(forKey: Self.exampleAssistant1Key, default: Self.defaultExampleAssistant1)
        let exampleUser2 = Self.storedExample(forKey: Self.exampleUser2Key, default: Self.defaultExampleUser2)
        let exampleAssistant2 = Self.storedExample(forKey: Self.exampleAssistant2Key, default: Self.defaultExampleAssistant2)

        let result = try await container.perform { context in
            let chat: [Chat.Message] = [
                .system(systemPrompt),
                .user(exampleUser1),
                .assistant(exampleAssistant1),
                .user(exampleUser2),
                .assistant(exampleAssistant2),
                .user(text),
            ]
            let userInput = UserInput(chat: chat)
            let lmInput = try await context.processor.prepare(input: userInput)

            return try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            ) { tokens in
                tokens.count < 512 ? .more : .stop
            }
        }

        let trimmed = result.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}

enum MLXRefinerError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Built-in LLM model is not loaded"
        }
    }
}
