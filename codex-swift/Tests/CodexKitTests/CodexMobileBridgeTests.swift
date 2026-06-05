//
//  CodexMobileBridgeTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

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


@Test
func builtinShellSchemasExposeOneShotUnifiedExecControls() throws {
    let tools = CodexMobileCoreBridge.builtinTools()
    let shell = try #require(tools.first { $0["name"] as? String == "shell_command" })
    let shellParameters = try #require(shell["parameters"] as? [String: Any])
    let shellProperties = try #require(shellParameters["properties"] as? [String: Any])
    let exec = try #require(tools.first { $0["name"] as? String == "exec_command" })
    let execParameters = try #require(exec["parameters"] as? [String: Any])
    let execProperties = try #require(execParameters["properties"] as? [String: Any])

    #expect((shell["description"] as? String)?.contains("one-shot") == true)
    #expect(shellProperties.keys.contains("timeout_ms"))
    #expect(shellProperties.keys.contains("max_output_tokens"))
    #expect(shellProperties.keys.contains("max_output_bytes"))
    #expect(shellProperties.keys.contains("login"))
    #expect(shellProperties.keys.contains("sandbox_permissions"))
    #expect((exec["description"] as? String)?.contains("session_id") == true)
    #expect(execProperties.keys.contains("timeout_ms"))
    #expect(execProperties.keys.contains("yield_time_ms"))
    #expect(execProperties.keys.contains("max_output_tokens"))
    #expect(execProperties.keys.contains("max_output_bytes"))
    #expect(execProperties.keys.contains("login"))
    #expect(execProperties.keys.contains("sandbox_permissions"))
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
        "text": ["verbosity": "high"],
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
    #expect((value?["text"] as? [String: Any])?["verbosity"] as? String == "high")
    #expect(content?[0]["text"] as? String == "look")
    #expect(content?[1]["image_url"] as? String == "data:image/png;base64,AAEC")
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
