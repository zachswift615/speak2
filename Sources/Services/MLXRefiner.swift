import Foundation
import MLXLLM
import MLXLMCommon
import MLX

actor MLXRefiner {
    static let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

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

    func refine(text: String, customPrompt: String? = nil) async throws -> String {
        guard let container = modelContainer else {
            throw MLXRefinerError.modelNotLoaded
        }

        let systemPrompt = customPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? OllamaRefiner.defaultPrompt

        let parameters = GenerateParameters(
            maxTokens: 512,
            temperature: 0.1
        )

        let result = try await container.perform { context in
            let chat: [Chat.Message] = [
                .system(systemPrompt),
                .user("<transcription>\(text)</transcription>"),
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
