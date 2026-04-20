import Foundation
import Testing
@testable import CodexKit
import CodexMobileCoreBridge

@Test
func providerDefaultsExposeOpenAIAndLocalProviders() {
    let providers = CodexProvider.defaults()

    #expect(providers.map(\.id) == ["openai", "lmstudio", "ollama"])
    #expect(providers[0].baseURL.absoluteString == "https://chatgpt.com/backend-api/codex")
    #expect(providers[1].baseURL.absoluteString == "http://127.0.0.1:1234/v1")
}

@Test
func authTokensResolveChatGPTAccountIDFromIDToken() throws {
    let idToken = try jwt(payload: [
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "account-123",
            "chatgpt_account_is_fedramp": false,
        ],
    ])
    let tokens = CodexAuthTokens(idToken: idToken, accessToken: "access", refreshToken: "refresh")

    #expect(tokens.resolvedChatGPTAccountID == "account-123")
}

@Test
func mobileBridgeBuildsResponsesRequest() throws {
    let body = try CodexMobileCoreBridge.buildResponsesRequest([
        "model": "gpt-5.4",
        "instructions": "Be concise",
        "input": [],
        "tools": CodexMobileCoreBridge.builtinTools(),
        "stream": true,
        "store": false,
        "reasoning": NSNull(),
        "promptCacheKey": "conversation-1",
    ])
    let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]

    #expect(value?["model"] as? String == "gpt-5.4")
    #expect(value?["instructions"] as? String == "Be concise")
    #expect((value?["tools"] as? [[String: Any]])?.first?["name"] as? String == "list_dir")
    #expect(value?["store"] as? Bool == false)
    #expect(value?["reasoning"] is NSNull)
    #expect(value?["prompt_cache_key"] as? String == "conversation-1")
}

@Test
func mobileBridgeNormalizesTextDelta() throws {
    let event = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.output_text.delta","delta":"hello"}"#.utf8)
    )

    #expect(event["type"] as? String == "outputTextDelta")
    #expect(event["delta"] as? String == "hello")
}

@Test
func toolOutputUsesResponsesFunctionCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: false,
        name: nil
    )

    #expect(output["type"] as? String == "function_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["output"] as? String == "done")
}

@Test
func sessionExecutesBuiltinWorkspaceTools() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root)
    ))
    let listData = try await session.executeToolCall(CodexToolCall(
        callID: "call-list",
        name: "list_dir",
        arguments: #"{"dir_path":"."}"#
    ))
    let listOutput = try toolOutputBody(listData)

    let catData = try await session.executeToolCall(CodexToolCall(
        callID: "call-cat",
        name: "shell_command",
        arguments: #"{"command":"cat notes.txt"}"#
    ))
    let catOutput = try toolOutputBody(catData)

    #expect(listOutput.contains("notes.txt"))
    #expect(catOutput == "hello\n")
}

private func jwt(payload: [String: Any]) throws -> String {
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadPart = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payloadPart).signature"
}

private func toolOutputBody(_ data: Data) throws -> String {
    let item = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return item?["output"] as? String ?? ""
}
