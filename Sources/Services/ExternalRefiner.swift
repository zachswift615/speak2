import Foundation

/// Settings for the external refinement server, and a single entry point that sends
/// a transcription to it in whichever API format the user chose.
struct ExternalRefiner {
    static let apiKeyAccount = "openAIAPIKey"

    var format: ExternalAPIFormat
    var baseURL: String
    var model: String
    var apiKey: String?

    /// The configuration saved in Settings.
    static var saved: ExternalRefiner {
        let defaults = UserDefaults.standard
        switch ExternalAPIFormat.saved {
        case .ollama:
            return ExternalRefiner(
                format: .ollama,
                baseURL: defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434",
                model: defaults.string(forKey: "ollamaModel") ?? "gemma3:4b"
            )
        case .openAICompatible:
            return ExternalRefiner(
                format: .openAICompatible,
                baseURL: defaults.string(forKey: "openAIBaseURL") ?? "",
                model: defaults.string(forKey: "openAIModel") ?? "",
                apiKey: KeychainStore.string(for: apiKeyAccount)
            )
        }
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func refine(text: String, customPrompt: String? = nil, languageName: String? = nil) async throws -> String {
        switch format {
        case .ollama:
            return try await OllamaRefiner.refine(
                text: text, baseURL: baseURL, model: model,
                customPrompt: customPrompt, languageName: languageName
            )
        case .openAICompatible:
            return try await OpenAICompatibleRefiner.refine(
                text: text, baseURL: baseURL, model: model, apiKey: apiKey,
                customPrompt: customPrompt, languageName: languageName
            )
        }
    }

    // MARK: - Privacy

    /// The host dictation would leave the local network for, or nil when the server is on
    /// this Mac or a private network (or the URL can't be parsed yet).
    static func remoteHost(for baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased(), !host.isEmpty else { return nil }
        return isLocal(host) ? nil : host
    }

    static func isLocal(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan") {
            return true
        }

        // IPv6 loopback, unique-local (fc00::/7) and link-local (fe80::/10)
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }
}
