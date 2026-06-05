import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(CodexMobileCore)
import CodexMobileCore
#endif
#if canImport(JustBash) && canImport(JustBashFS)
import JustBash
import JustBashCommands
import JustBashFS
#endif
#if canImport(JustBashJavaScript)
import JustBashJavaScript
#endif

public enum CodexMobileCoreBridge {
    public static func version() -> [String: Any] {
        #if canImport(CodexMobileCore)
        if let version = try? rustObject(codex_mobile_core_version_json()) {
            return version
        }
        #endif
        return fallbackVersion()
    }

    public static func providerDefaults() -> [[String: Any]] {
        #if canImport(CodexMobileCore)
        if let object = try? rustObject(codex_mobile_provider_defaults_json()),
           let providers = object["providers"] as? [[String: Any]]
        {
            return providers
        }
        #endif
        return fallbackProviderDefaults()
    }

    public static func builtinTools() -> [[String: Any]] {
        #if canImport(CodexMobileCore)
        if let object = try? rustObject(codex_mobile_builtin_tools_json()),
           let tools = object["tools"] as? [[String: Any]]
        {
            return mergedBuiltinTools(tools)
        }
        #endif
        return fallbackBuiltinTools()
    }

    public static func buildResponsesRequest(_ input: [String: Any]) throws -> Data {
        #if canImport(CodexMobileCore)
        return try rustData(input: input, codex_mobile_build_responses_request_json)
        #else
        return try fallbackBuildResponsesRequest(input)
        #endif
    }

    public static func parseSSEEvent(_ data: Data) throws -> [String: Any] {
        #if canImport(CodexMobileCore)
        let text = String(decoding: data, as: UTF8.self)
        let output = try rustData(input: text, codex_mobile_parse_sse_event_json)
        return try decodeObject(output)
        #else
        return try fallbackParseSSEEvent(data)
        #endif
    }

    public static func toolOutput(callID: String, output: Any, success: Bool, custom: Bool, name: String?) -> [String: Any] {
        if isToolOutputContentItems(output) {
            return fallbackToolOutput(callID: callID, output: output, success: success, custom: custom, name: name)
        }
        #if canImport(CodexMobileCore)
        let input: [String: Any] = [
            "callId": callID,
            "name": name as Any,
            "output": output,
            "success": success,
            "custom": custom,
        ]
        if let data = try? rustData(input: input, codex_mobile_tool_output_json),
           let object = try? decodeObject(data)
        {
            return object
        }
        #endif
        return fallbackToolOutput(callID: callID, output: output, success: success, custom: custom, name: name)
    }

    public static func emulateShell(_ input: [String: Any]) async throws -> [String: Any] {
        try await emulateShell(input, outputHandler: nil)
    }

    public static func emulateShell(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> [String: Any] {
        #if os(macOS)
        return runNativeShell(input, outputHandler: outputHandler)
        #else
        #if canImport(JustBash) && canImport(JustBashFS)
        return await runJustBashShell(input, outputHandler: outputHandler)
        #elseif canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_emulate_shell_json)
        let object = try decodeObject(data)
        if let output = object["output"] as? String, !output.isEmpty {
            outputHandler?(output)
        }
        return object
        #else
        let object = fallbackEmulateShell(input)
        if let output = object["output"] as? String, !output.isEmpty {
            outputHandler?(output)
        }
        return object
        #endif
        #endif
    }

    public static func applyPatch(_ input: [String: Any]) throws -> [String: Any] {
        #if os(macOS)
        return nativeApplyPatch(input)
        #else
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_apply_patch_json)
        return try decodeObject(data)
        #else
        return fallbackApplyPatch(input)
        #endif
        #endif
    }

    public static func refreshTokenRequest(clientID: String, refreshToken: String) throws -> [String: Any] {
        let input = ["clientId": clientID, "refreshToken": refreshToken]
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_refresh_token_request_json)
        return try decodeObject(data)
        #else
        return fallbackRefreshTokenRequest(clientID: clientID, refreshToken: refreshToken)
        #endif
    }

    public static func authorizationURL(
        issuer: URL,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        let input: [String: Any] = [
            "issuer": issuer.absoluteString,
            "clientId": clientID,
            "redirectUri": redirectURI,
            "state": state,
            "codeChallenge": codeChallenge,
        ]
        let object: [String: Any]
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_authorization_url_json)
        object = try decodeObject(data)
        #else
        object = fallbackAuthorizationURL(input)
        #endif
        guard let value = object["url"] as? String, let url = URL(string: value) else {
            throw CodexMobileCoreBridgeError.invalidURL
        }
        return url
    }

    public static func authorizationCodeTokenRequest(
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) throws -> [String: Any] {
        let input: [String: Any] = [
            "clientId": clientID,
            "code": code,
            "codeVerifier": codeVerifier,
            "redirectUri": redirectURI,
        ]
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_authorization_code_token_request_json)
        return try decodeObject(data)
        #else
        return fallbackAuthorizationCodeTokenRequest(input)
        #endif
    }

    public static func parseChatGPTTokenClaims(token: String) throws -> [String: Any] {
        #if canImport(CodexMobileCore)
        let data = try rustData(input: ["token": token], codex_mobile_parse_chatgpt_token_claims_json)
        return try decodeObject(data)
        #else
        return try fallbackParseChatGPTTokenClaims(token: token)
        #endif
    }

    public static func deviceKeySigningPayload(_ payload: [String: Any]) throws -> Data {
        #if canImport(CodexMobileCore)
        let data = try rustData(input: ["payload": payload], codex_mobile_device_key_signing_payload_json)
        let object = try decodeObject(data)
        guard
            let encoded = object["signedPayloadBase64"] as? String,
            let signedPayload = Data(base64Encoded: encoded)
        else {
            throw CodexMobileCoreBridgeError.invalidJSON
        }
        return signedPayload
        #else
        return try fallbackDeviceKeySigningPayload(payload)
        #endif
    }
}

public enum CodexMobileCoreBridgeError: Error, Equatable {
    case missingField(String)
    case rustError(String)
    case invalidJSON
    case invalidJWT
    case invalidURL
}
