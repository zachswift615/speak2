import XCTest
@testable import Speak2

final class OpenAICompatibleRefinerTests: XCTestCase {

    // MARK: - URL Building

    func testBuildAPIURLAppendsChatCompletions() throws {
        let url = try OpenAICompatibleRefiner.buildAPIURL(from: "http://localhost:4000/v1/")
        XCTAssertEqual(url.absoluteString, "http://localhost:4000/v1/chat/completions")
    }

    func testBuildAPIURLKeepsFullEndpoint() throws {
        let url = try OpenAICompatibleRefiner.buildAPIURL(from: " https://api.openai.com/v1/chat/completions ")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testBuildAPIURLRejectsMissingScheme() {
        XCTAssertThrowsError(try OpenAICompatibleRefiner.buildAPIURL(from: "localhost:4000/v1"))
    }

    // MARK: - Request Body

    func testRequestBodySplitsInstructionsAndTranscription() throws {
        let body = OpenAICompatibleRefiner.buildRequestBody(
            model: "qwen3-27b", text: "um hello", customPrompt: nil, languageName: "German"
        )
        XCTAssertEqual(body["model"] as? String, "qwen3-27b")
        XCTAssertEqual(body["stream"] as? Bool, false)

        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]!.hasPrefix(OllamaRefiner.defaultPrompt))
        XCTAssertTrue(messages[0]["content"]!.contains("German"))
        XCTAssertEqual(messages[1]["content"], "<transcription>um hello</transcription>")
    }

    // MARK: - Response Parsing

    private func response(content: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    func testParseResponseExtractsContent() throws {
        let result = try OpenAICompatibleRefiner.parseResponse(data: response(content: " Hello there\n"), originalText: "um hello there")
        XCTAssertEqual(result, "Hello there")
    }

    func testParseResponseStripsReasoning() throws {
        let result = try OpenAICompatibleRefiner.parseResponse(
            data: response(content: "<think>clean it up</think>Hello there"), originalText: "um hello there"
        )
        XCTAssertEqual(result, "Hello there")
    }

    func testParseResponseFallsBackOnEmptyContent() throws {
        let result = try OpenAICompatibleRefiner.parseResponse(data: response(content: ""), originalText: "um hello there")
        XCTAssertEqual(result, "um hello there")
    }

    func testParseResponseThrowsWithoutChoices() throws {
        let data = try JSONSerialization.data(withJSONObject: ["response": "Hello"])
        XCTAssertThrowsError(try OpenAICompatibleRefiner.parseResponse(data: data, originalText: "x"))
    }

    // MARK: - Errors

    func testErrorMessageReadsOpenAIErrorBody() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": "Invalid API key", "type": "auth"]])
        XCTAssertEqual(OpenAICompatibleRefiner.errorMessage(from: data), "Invalid API key")
    }

    func testErrorMessageReadsPlainStringError() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": "model not found"])
        XCTAssertEqual(OpenAICompatibleRefiner.errorMessage(from: data), "model not found")
    }

    func testUnauthorizedErrorMentionsAPIKey() {
        let error = OpenAICompatibleError.requestFailed(status: 401, message: nil)
        XCTAssertTrue(error.localizedDescription.contains("API key"))
    }

    // MARK: - Privacy

    func testLocalHostsAreNotReportedAsRemote() {
        for url in [
            "http://localhost:4000/v1", "http://127.0.0.1:1234/v1", "http://192.168.1.20:8000/v1",
            "http://10.0.0.5/v1", "http://172.20.1.1/v1", "http://studio.local:1234/v1", "http://[::1]:8080/v1"
        ] {
            XCTAssertNil(ExternalRefiner.remoteHost(for: url), url)
        }
    }

    func testRemoteHostsAreReported() {
        XCTAssertEqual(ExternalRefiner.remoteHost(for: "https://api.openai.com/v1"), "api.openai.com")
        XCTAssertEqual(ExternalRefiner.remoteHost(for: "http://172.32.0.1/v1"), "172.32.0.1")
        XCTAssertEqual(ExternalRefiner.remoteHost(for: "https://llm.example.com/v1"), "llm.example.com")
    }

    func testUnparseableURLShowsNoNotice() {
        XCTAssertNil(ExternalRefiner.remoteHost(for: ""))
        XCTAssertNil(ExternalRefiner.remoteHost(for: "localhost:4000"))
    }

    // MARK: - Integration

    func testRefineThrowsForUnreachableServer() async {
        do {
            _ = try await OpenAICompatibleRefiner.refine(
                text: "hello", baseURL: "http://127.0.0.1:1/v1", model: "test", apiKey: nil
            )
            XCTFail("Expected an error for an unreachable server")
        } catch {
            // Expected
        }
    }
}
