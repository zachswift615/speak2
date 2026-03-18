import Foundation

struct OllamaRefiner {
    /// Sends transcribed text to an Ollama model for cleanup and returns the refined result.
    /// Falls back to the original text on any error.
    static let defaultPrompt = """
        You are editing a voice dictation message. Clean it up for readability while preserving the exact meaning and intent.

        Remove filler words, repeated phrases, and false starts. Fix grammar, spelling, and punctuation. Correct obvious speech-to-text mistakes when the intended word is clear. Preserve names, numbers, and technical terms exactly. Do not answer questions, add information, or summarize. If something is unclear, keep the original wording.

        Return only the cleaned message.

        Message:
        """

    /// Build the full prompt from user text and an optional custom prompt.
    static func buildPrompt(text: String, customPrompt: String? = nil) -> String {
        let promptBase = customPrompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? defaultPrompt
        return "\(promptBase)\n\n<transcription>\(text)</transcription>"
    }

    /// Build and validate the API URL from a base URL string.
    static func buildAPIURL(from baseURL: String) throws -> URL {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let apiURL = URL(string: "\(trimmedURL)/api/generate") else {
            throw OllamaError.invalidURL
        }
        return apiURL
    }

    /// Parse the Ollama JSON response, returning the refined text or falling back to the original.
    static func parseResponse(data: Data, originalText: String) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refined = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? originalText : trimmed
    }

    static func refine(text: String, baseURL: String, model: String, customPrompt: String? = nil) async throws -> String {
        let apiURL = try buildAPIURL(from: baseURL)
        let prompt = buildPrompt(text: text, customPrompt: customPrompt)

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        return try parseResponse(data: data, originalText: text)
    }
}

enum OllamaError: LocalizedError {
    case invalidURL
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Ollama URL"
        case .requestFailed: return "Ollama request failed — check that the server is running or if the model is available"
        case .invalidResponse: return "Unexpected response from Ollama"
        }
    }
}
