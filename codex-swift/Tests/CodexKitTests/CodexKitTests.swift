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
            "chatgpt_plan_type": "plus",
            "chatgpt_user_id": "user-123",
            "chatgpt_account_is_fedramp": false,
        ],
        "email": "dev@example.com",
    ])
    let tokens = CodexAuthTokens(idToken: idToken, accessToken: "access", refreshToken: "refresh")

    #expect(tokens.resolvedChatGPTAccountID == "account-123")
    #expect(tokens.resolvedAccountMetadata.planType == "plus")
    #expect(tokens.resolvedAccountMetadata.userID == "user-123")
    #expect(tokens.resolvedAccountMetadata.email == "dev@example.com")
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
    let toolNames = Set((value?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
    #expect(toolNames.isSuperset(of: ["list_dir", "read_file", "search_files", "apply_patch", "write_file", "shell_command", "exec_command"]))
    #expect(value?["store"] as? Bool == false)
    #expect(value?["reasoning"] is NSNull)
    #expect(value?["prompt_cache_key"] as? String == "conversation-1")
}

#if os(macOS)
@Test
func mobileBridgeAppliesPatchWithoutMobileCoreOnMacOS() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "old\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    try "gone\n".write(to: root.appending(path: "obsolete.txt"), atomically: true, encoding: .utf8)

    let response = try CodexMobileCoreBridge.applyPatch([
        "workspaceRoot": root.path,
        "patch": """
        *** Begin Patch
        *** Update File: notes.txt
        @@
        -old
        +new
        *** Add File: nested/added.txt
        +added
        *** Delete File: obsolete.txt
        *** End Patch
        """,
    ])

    #expect(response["exit_code"] as? Int == 0)
    #expect((response["output"] as? String)?.contains("M notes.txt") == true)
    #expect((response["output"] as? String)?.contains("A nested/added.txt") == true)
    #expect((response["output"] as? String)?.contains("D obsolete.txt") == true)
    #expect(try String(contentsOf: root.appending(path: "notes.txt"), encoding: .utf8) == "new\n")
    #expect(try String(contentsOf: root.appending(path: "nested/added.txt"), encoding: .utf8) == "added\n")
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "obsolete.txt").path))
}

@Test
func mobileBridgeApplyPatchRejectsMacOSWorkspaceEscapes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let outside = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let response = try CodexMobileCoreBridge.applyPatch([
        "workspaceRoot": root.path,
        "patch": """
        *** Begin Patch
        *** Add File: \(outside.path)/escape.txt
        +bad
        *** End Patch
        """,
    ])

    #expect(response["exit_code"] as? Int == 1)
    #expect((response["output"] as? String)?.contains("escapes workspace") == true)
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "escape.txt").path))
}
#endif

@Test
func mobileBridgeBuildsTurnOptionsAndMultipartInput() throws {
    let imageData = Data([0, 1, 2])
    let inputParts = [
        CodexInput.text("look").responsesContentPart,
        CodexInput.imageData(imageData, mimeType: "image/png").responsesContentPart,
    ]
    let body = try CodexMobileCoreBridge.buildResponsesRequest([
        "model": "gpt-5.4-mini",
        "input": [["type": "message", "role": "user", "content": inputParts]],
        "tools": [],
        "stream": true,
        "store": false,
        "reasoning": ["effort": "low"],
        "serviceTier": "flex",
        "toolChoice": "required",
        "parallelToolCalls": false,
    ])
    let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let input = value?["input"] as? [[String: Any]]
    let content = input?.first?["content"] as? [[String: Any]]

    #expect(value?["model"] as? String == "gpt-5.4-mini")
    #expect(value?["service_tier"] as? String == "flex")
    #expect(value?["tool_choice"] as? String == "required")
    #expect(value?["parallel_tool_calls"] as? Bool == false)
    #expect((value?["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    #expect(content?[0]["text"] as? String == "look")
    #expect(content?[1]["image_url"] as? String == "data:image/png;base64,AAEC")
}

@Test
func mobileBridgeNormalizesTextDelta() throws {
    let event = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.output_text.delta","item_id":"msg-1","delta":"hello"}"#.utf8)
    )

    #expect(event["type"] as? String == "outputTextDelta")
    #expect(event["itemId"] as? String == "msg-1")
    #expect(event["delta"] as? String == "hello")
}

@Test
func sessionDecodesReasoningAndToolArgumentDeltas() throws {
    let reasoning = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","delta":"working"}"#.utf8)
    )
    let arguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","output_index":0,"delta":"{\"path\""}"#.utf8)
    )

    #expect(try CodexSession.decodeStreamEvent(reasoning) == .reasoningSummaryDelta(itemID: "rs-1", delta: "working"))
    #expect(try CodexSession.decodeStreamEvent(arguments) == .toolCallInputDelta(
        itemID: "item-1",
        callID: "call-1",
        delta: #"{"path""#
    ))
}

@Test
func mobileBridgeNormalizesBothToolInputDeltaNames() throws {
    let functionArguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","delta":"{\""}"#.utf8)
    )
    let toolInput = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.tool_call_input.delta","item_id":"item-2","call_id":"call-2","delta":"path"}"#.utf8)
    )

    #expect(functionArguments["type"] as? String == "toolCallInputDelta")
    #expect(functionArguments["callId"] as? String == "call-1")
    #expect(toolInput["type"] as? String == "toolCallInputDelta")
    #expect(toolInput["itemId"] as? String == "item-2")
    #expect(toolInput["callId"] as? String == "call-2")
}

@Test
func sessionDecodesAssistantItemLifecycle() throws {
    let started = try CodexSession.decodeStreamEvent([
        "type": "outputItemAdded",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
        ],
    ])
    let completed = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "output_text", "text": "Hello"],
            ],
        ],
    ])

    #expect(started == .outputItemStarted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant")))
    #expect(completed == .outputItemCompleted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant", text: "Hello")))
}

@Test
func sessionPreservesCustomToolCallKind() throws {
    let event = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "item-1",
            "type": "custom_tool_call",
            "call_id": "call-1",
            "name": "custom",
            "input": #"{"value":1}"#,
        ],
    ])

    guard case .outputItemCompleted(let item) = event, let call = item.toolCall else {
        Issue.record("Expected completed custom tool item")
        return
    }
    #expect(call.itemID == "item-1")
    #expect(call.kind == .custom)
    #expect(call.arguments == #"{"value":1}"#)
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
func toolOutputUsesResponsesCustomToolCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: true,
        name: "custom"
    )

    #expect(output["type"] as? String == "custom_tool_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["name"] as? String == "custom")
    #expect(output["output"] as? String == "done")
}

@Test
func mobileBridgeExposesAuthRefreshAndBrowserRequests() throws {
    let refresh = try CodexMobileCoreBridge.refreshTokenRequest(
        clientID: "client",
        refreshToken: "refresh"
    )
    let authorizationURL = try CodexMobileCoreBridge.authorizationURL(
        issuer: URL(string: "https://auth.openai.com")!,
        clientID: "client",
        redirectURI: "http://localhost:1455/auth/callback",
        state: "state",
        codeChallenge: "challenge"
    )
    let token = try CodexMobileCoreBridge.authorizationCodeTokenRequest(
        clientID: "client",
        code: "code",
        codeVerifier: "verifier",
        redirectURI: "http://localhost:1455/auth/callback"
    )

    #expect((refresh["body"] as? [String: Any])?["grant_type"] as? String == "refresh_token")
    #expect(authorizationURL.absoluteString.contains("code_challenge=challenge"))
    #expect(token["path"] as? String == "/oauth/token")
    #expect(token["body"] as? String == "grant_type=authorization_code&code=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=client&code_verifier=verifier")
}

@Test
func deviceKeyPayloadUsesRustCanonicalSigningBytes() throws {
    let payload = CodexDeviceKeySignPayload.remoteControlClientConnection(.init(
        nonce: "nonce",
        sessionID: "session",
        targetOrigin: "https://chatgpt.com",
        targetPath: "/api/codex/remote/control/client",
        accountUserID: "user",
        clientID: "client",
        tokenExpiresAt: 123,
        tokenSHA256Base64URL: "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"
    ))

    let bytes = try payload.signingPayloadBytes()
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(text == #"{"domain":"codex-device-key-sign-payload/v1","payload":{"accountUserId":"user","audience":"remote_control_client_websocket","clientId":"client","nonce":"nonce","scopes":["remote_control_controller_websocket"],"sessionId":"session","targetOrigin":"https://chatgpt.com","targetPath":"/api/codex/remote/control/client","tokenExpiresAt":123,"tokenSha256Base64url":"47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU","type":"remoteControlClientConnection"}}"#)
}

@Test
func jsonSchemaBuilderProducesToolInputSchema() {
    let schema = CodexJSONSchema.object(
        properties: [
            "path": .string(description: "File path"),
            "mode": .stringEnum(["read", "write"]),
            "recursive": .boolean(),
        ],
        required: ["path"]
    )
    let properties = schema.inputSchema["properties"] as? [String: any Sendable]
    let path = properties?["path"] as? [String: any Sendable]
    let mode = properties?["mode"] as? [String: any Sendable]

    #expect(schema.inputSchema["type"] as? String == "object")
    #expect(path?["description"] as? String == "File path")
    #expect(mode?["enum"] as? [String] == ["read", "write"])
}

@Test
func workspaceStoreRoundTripsSecurityScopedWorkspaceRecord() throws {
    let suiteName = "CodexWorkspaceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let workspace = CodexWorkspace(rootURL: root, bookmarkData: Data([1, 2, 3]), readOnly: true)
    let store = CodexWorkspaceStore(defaults: defaults)

    let record = try store.save(workspace, displayName: "Demo")
    let resolved = try store.resolve(record)

    #expect(try store.list() == [record])
    #expect(resolved.rootURL.path == root.path)
    #expect(resolved.bookmarkData == Data([1, 2, 3]))
    #expect(resolved.readOnly == true)
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

    let readData = try await session.executeToolCall(CodexToolCall(
        callID: "call-read",
        name: "read_file",
        arguments: #"{"path":"notes.txt"}"#
    ))
    let readOutput = try toolOutputBody(readData)

    let searchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-search",
        name: "search_files",
        arguments: #"{"query":"hello","path":"."}"#
    ))
    let searchOutput = try toolOutputBody(searchData)

    let catData = try await session.executeToolCall(CodexToolCall(
        callID: "call-cat",
        name: "shell_command",
        arguments: #"{"command":"cat notes.txt"}"#
    ))
    let catOutput = try toolOutputBody(catData)

    #expect(listOutput.contains("notes.txt"))
    #expect(readOutput == "hello\n")
    #expect(searchOutput.contains("notes.txt:1: hello"))
    #expect(catOutput == "hello\n")

    let patch = """
    *** Begin Patch
    *** Add File: added.txt
    +patched
    *** End Patch
    """
    let patchArguments = try jsonString(["patch": patch])
    let patchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-patch",
        name: "apply_patch",
        arguments: patchArguments
    ))
    let patchOutput = try toolOutputBody(patchData)

    #expect(patchOutput.contains("A added.txt"))
    #expect(try String(contentsOf: root.appending(path: "added.txt"), encoding: .utf8) == "patched\n")

    let writeData = try await session.executeToolCall(CodexToolCall(
        callID: "call-write",
        name: "write_file",
        arguments: try jsonString(["path": "written.txt", "content": "written\n"])
    ))
    let writeOutput = try toolOutputBody(writeData)

    #expect(writeOutput.contains("Wrote written.txt"))
    #expect(try String(contentsOf: root.appending(path: "written.txt"), encoding: .utf8) == "written\n")
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

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
