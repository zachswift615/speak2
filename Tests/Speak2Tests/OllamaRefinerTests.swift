import XCTest
@testable import Speak2

final class OllamaRefinerTests: XCTestCase {

    // MARK: - Default Prompt

    func testDefaultPromptIsNonEmpty() {
        XCTAssertFalse(OllamaRefiner.defaultPrompt.isEmpty)
    }

    func testDefaultPromptContainsCleanupInstructions() {
        let prompt = OllamaRefiner.defaultPrompt
        XCTAssertTrue(prompt.contains("filler words"), "Default prompt should mention filler words")
        XCTAssertTrue(prompt.contains("Return only"), "Default prompt should request only the cleaned message")
    }

    // MARK: - Request Body

    func testRequestBodyDisablesThinkingAndStreaming() {
        let body = OllamaRefiner.buildRequestBody(model: "gemma4:26b-mlx", prompt: "hello")
        XCTAssertEqual(body["model"] as? String, "gemma4:26b-mlx")
        XCTAssertEqual(body["prompt"] as? String, "hello")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false, "Thinking must be disabled so reasoning models answer immediately")
    }

    // MARK: - Prompt Building

    func testBuildPromptUsesDefaultWhenNilCustomPrompt() {
        let result = OllamaRefiner.buildPrompt(text: "hello world", customPrompt: nil)
        XCTAssertTrue(result.hasPrefix(OllamaRefiner.defaultPrompt))
        XCTAssertTrue(result.contains("<transcription>hello world</transcription>"))
    }

    func testBuildPromptUsesDefaultWhenEmptyCustomPrompt() {
        let result = OllamaRefiner.buildPrompt(text: "hello world", customPrompt: "")
        XCTAssertTrue(result.hasPrefix(OllamaRefiner.defaultPrompt))
    }

    func testBuildPromptUsesDefaultWhenWhitespaceOnlyCustomPrompt() {
        let result = OllamaRefiner.buildPrompt(text: "hello world", customPrompt: "   \n  ")
        XCTAssertTrue(result.hasPrefix(OllamaRefiner.defaultPrompt))
    }

    func testBuildPromptUsesCustomWhenProvided() {
        let custom = "Translate to French:"
        let result = OllamaRefiner.buildPrompt(text: "hello world", customPrompt: custom)
        XCTAssertTrue(result.hasPrefix(custom))
        XCTAssertFalse(result.contains(OllamaRefiner.defaultPrompt))
    }

    func testBuildPromptSeparatesPromptAndTextWithDoubleNewline() {
        let result = OllamaRefiner.buildPrompt(text: "test input", customPrompt: "My prompt:")
        XCTAssertEqual(result, "My prompt:\n\n<transcription>test input</transcription>")
    }

    func testBuildPromptPreservesTextExactly() {
        let text = "um so I wanted to uh say hello"
        let result = OllamaRefiner.buildPrompt(text: text)
        XCTAssertTrue(result.contains("<transcription>\(text)</transcription>"))
    }

    // MARK: - Language Directive

    func testBuildPromptAppendsLanguageDirectiveWhenLanguageProvided() {
        let result = OllamaRefiner.buildPrompt(text: "hallo welt", customPrompt: nil, languageName: "German")
        XCTAssertTrue(result.contains("German"), "Prompt should name the selected language")
        XCTAssertTrue(result.contains("<transcription>hallo welt</transcription>"))
    }

    func testBuildPromptOmitsLanguageDirectiveWhenNil() {
        let withNil = OllamaRefiner.buildPrompt(text: "x", customPrompt: nil, languageName: nil)
        let withoutArg = OllamaRefiner.buildPrompt(text: "x", customPrompt: nil)
        XCTAssertEqual(withNil, withoutArg, "No language directive should be added when language is nil")
    }

    // MARK: - URL Building

    func testBuildAPIURLWithValidURL() throws {
        let url = try OllamaRefiner.buildAPIURL(from: "http://localhost:11434")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/generate")
    }

    func testBuildAPIURLTrimsTrailingSlash() throws {
        let url = try OllamaRefiner.buildAPIURL(from: "http://localhost:11434/")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/generate")
    }

    func testBuildAPIURLTrimsMultipleTrailingSlashes() throws {
        let url = try OllamaRefiner.buildAPIURL(from: "http://localhost:11434///")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/generate")
    }

    func testBuildAPIURLTrimsWhitespace() throws {
        let url = try OllamaRefiner.buildAPIURL(from: "  http://localhost:11434  ")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/generate")
    }

    func testBuildAPIURLWithCustomPort() throws {
        let url = try OllamaRefiner.buildAPIURL(from: "http://192.168.1.100:8080")
        XCTAssertEqual(url.absoluteString, "http://192.168.1.100:8080/api/generate")
    }

    func testBuildAPIURLWithEmptyStringProducesRelativeURL() throws {
        // Empty base URL produces a relative URL — this is valid per URL(string:)
        let url = try OllamaRefiner.buildAPIURL(from: "")
        XCTAssertEqual(url.absoluteString, "/api/generate")
    }

    // MARK: - Response Parsing

    func testParseResponseExtractsText() throws {
        let json: [String: Any] = ["response": "Hello there"]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = try OllamaRefiner.parseResponse(data: data, originalText: "um hello there")
        XCTAssertEqual(result, "Hello there")
    }

    func testParseResponseTrimsWhitespace() throws {
        let json: [String: Any] = ["response": "  Hello there  \n"]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = try OllamaRefiner.parseResponse(data: data, originalText: "um hello there")
        XCTAssertEqual(result, "Hello there")
    }

    func testParseResponseFallsBackOnEmptyResponse() throws {
        let json: [String: Any] = ["response": ""]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = try OllamaRefiner.parseResponse(data: data, originalText: "original text")
        XCTAssertEqual(result, "original text")
    }

    func testParseResponseFallsBackOnWhitespaceOnlyResponse() throws {
        let json: [String: Any] = ["response": "   \n\t  "]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = try OllamaRefiner.parseResponse(data: data, originalText: "original text")
        XCTAssertEqual(result, "original text")
    }

    func testParseResponseThrowsOnMissingResponseKey() {
        let json: [String: Any] = ["model": "gemma3:4b", "done": true]
        let data = try! JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try OllamaRefiner.parseResponse(data: data, originalText: "test")) { error in
            XCTAssertEqual(error as? OllamaError, .invalidResponse)
        }
    }

    func testParseResponseThrowsOnInvalidJSON() {
        let data = "not json".data(using: .utf8)!

        XCTAssertThrowsError(try OllamaRefiner.parseResponse(data: data, originalText: "test"))
    }

    func testParseResponseThrowsOnNonStringResponse() {
        let json: [String: Any] = ["response": 42]
        let data = try! JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try OllamaRefiner.parseResponse(data: data, originalText: "test")) { error in
            XCTAssertEqual(error as? OllamaError, .invalidResponse)
        }
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        XCTAssertNotNil(OllamaError.invalidURL.errorDescription)
        XCTAssertNotNil(OllamaError.requestFailed.errorDescription)
        XCTAssertNotNil(OllamaError.invalidResponse.errorDescription)
    }

    func testErrorDescriptionsAreUserFriendly() {
        // Error messages should be readable, not technical jargon
        XCTAssertTrue(OllamaError.invalidURL.errorDescription!.contains("URL"))
        XCTAssertTrue(OllamaError.requestFailed.errorDescription!.contains("server"))
        XCTAssertTrue(OllamaError.invalidResponse.errorDescription!.contains("response"))
    }

    // MARK: - Integration: refine() with unreachable server

    func testRefineThrowsWhenServerUnreachable() async {
        // Use a port that definitely isn't running Ollama
        do {
            _ = try await OllamaRefiner.refine(
                text: "hello world",
                baseURL: "http://127.0.0.1:19999",
                model: "test"
            )
            XCTFail("Expected refine to throw when server is unreachable")
        } catch {
            // Any error is expected — URLSession connection refused or timeout
            XCTAssertNotNil(error)
        }
    }

    func testRefineThrowsForInvalidURL() async {
        // A truly invalid URL that URL(string:) rejects
        do {
            _ = try await OllamaRefiner.refine(
                text: "hello",
                baseURL: "://bad url with spaces[]",
                model: "test"
            )
            XCTFail("Expected refine to throw for invalid URL")
        } catch {
            XCTAssertEqual(error as? OllamaError, .invalidURL)
        }
    }
}
