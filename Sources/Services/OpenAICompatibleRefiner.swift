import Foundation

/// Refines dictation through any server that implements OpenAI's `/chat/completions` API
/// (OpenAI, LiteLLM, LM Studio, vLLM, llama.cpp, OpenRouter, ...).
struct OpenAICompatibleRefiner {
    /// Build the chat completions URL from a base URL such as `http://localhost:4000/v1`.
    /// A URL that already ends in `/chat/completions` is used as is.
    static func buildAPIURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = trimmed.hasSuffix("/chat/completions") ? trimmed : "\(trimmed)/chat/completions"

        guard let url = URL(string: endpoint), url.scheme == "http" || url.scheme == "https" else {
            throw OpenAICompatibleError.invalidURL
        }
        return url
    }

    /// The instructions go in the system message and the transcription in the user message,
    /// so chat models edit the dictation rather than reply to it.
    static func buildRequestBody(model: String, text: String, customPrompt: String?, languageName: String?) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": OllamaRefiner.instructions(customPrompt: customPrompt, languageName: languageName)],
                ["role": "user", "content": OllamaRefiner.wrapTranscription(text)]
            ],
            "stream": false
        ]
    }

    static func parseResponse(data: Data, originalText: String) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAICompatibleError.invalidResponse
        }

        let trimmed = OllamaRefiner.stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? originalText : trimmed
    }

    /// The server's own explanation from an error body (`{"error": {"message": ...}}`), if any.
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["error"] as? String
    }

    static func refine(
        text: String,
        baseURL: String,
        model: String,
        apiKey: String?,
        customPrompt: String? = nil,
        languageName: String? = nil
    ) async throws -> String {
        var request = URLRequest(url: try buildAPIURL(from: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: buildRequestBody(model: model, text: text, customPrompt: customPrompt, languageName: languageName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw OpenAICompatibleError.requestFailed(status: httpResponse.statusCode, message: errorMessage(from: data))
        }

        return try parseResponse(data: data, originalText: text)
    }
}

enum OpenAICompatibleError: LocalizedError, Equatable {
    case invalidURL
    case requestFailed(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL — use something like http://localhost:4000/v1"
        case .requestFailed(let status, let message):
            if let message { return "Server returned \(status): \(message)" }
            if status == 401 { return "Server returned 401 — check the API key" }
            return "Server returned \(status) — check the URL and model name"
        case .invalidResponse:
            return "Unexpected response — is this an OpenAI-compatible server?"
        }
    }
}
