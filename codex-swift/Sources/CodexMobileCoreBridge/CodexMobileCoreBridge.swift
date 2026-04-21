import Foundation
#if canImport(CodexMobileCore)
import CodexMobileCore
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
            return tools
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

    public static func emulateShell(_ input: [String: Any]) throws -> [String: Any] {
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_emulate_shell_json)
        return try decodeObject(data)
        #else
        return fallbackEmulateShell(input)
        #endif
    }

    public static func applyPatch(_ input: [String: Any]) throws -> [String: Any] {
        #if canImport(CodexMobileCore)
        let data = try rustData(input: input, codex_mobile_apply_patch_json)
        return try decodeObject(data)
        #else
        return fallbackApplyPatch(input)
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

    private static func fallbackVersion() -> [String: Any] {
        [
            "crate": "codex-mobile-core",
            "version": "0.0.0",
            "abi": 1,
            "source": "swift-fallback",
        ]
    }

    private static func fallbackProviderDefaults() -> [[String: Any]] {
        [
            [
                "id": "openai",
                "name": "OpenAI",
                "baseUrl": "https://chatgpt.com/backend-api/codex",
                "requiresChatgptAuth": true,
                "supportsResponses": true,
                "supportsWebsockets": false,
            ],
            [
                "id": "lmstudio",
                "name": "LM Studio",
                "baseUrl": "http://127.0.0.1:1234/v1",
                "requiresChatgptAuth": false,
                "supportsResponses": true,
                "supportsWebsockets": false,
            ],
            [
                "id": "ollama",
                "name": "Ollama",
                "baseUrl": "http://127.0.0.1:11434/v1",
                "requiresChatgptAuth": false,
                "supportsResponses": true,
                "supportsWebsockets": false,
            ],
        ]
    }

    private static func fallbackBuiltinTools() -> [[String: Any]] {
        [
            functionTool(
                name: "list_dir",
                description: "Lists entries in a workspace directory with simple type labels.",
                required: ["dir_path"],
                properties: [
                    "dir_path": ["type": "string"],
                    "offset": ["type": "number"],
                    "limit": ["type": "number"],
                    "depth": ["type": "number"],
                ]
            ),
            functionTool(
                name: "apply_patch",
                description: "Applies a Codex apply_patch patch inside the active workspace.",
                required: ["patch"],
                properties: [
                    "patch": ["type": "string"],
                    "workdir": ["type": "string"],
                ]
            ),
            functionTool(
                name: "shell_command",
                description: "Runs a shell-like command. On iOS this is a deterministic Codex emulator.",
                required: ["command"],
                properties: [
                    "command": ["type": "string"],
                    "workdir": ["type": "string"],
                    "timeout_ms": ["type": "number"],
                ]
            ),
            functionTool(
                name: "exec_command",
                description: "Runs a shell-like command and returns Codex unified exec output.",
                required: ["cmd"],
                properties: [
                    "cmd": ["type": "string"],
                    "workdir": ["type": "string"],
                    "yield_time_ms": ["type": "number"],
                    "max_output_tokens": ["type": "number"],
                ]
            ),
        ]
    }

    private static func fallbackBuildResponsesRequest(_ input: [String: Any]) throws -> Data {
        var request: [String: Any] = [
            "model": try requiredString(input["model"], field: "model"),
            "input": input["input"] ?? [],
            "tools": input["tools"] ?? [],
            "tool_choice": input["toolChoice"] ?? "auto",
            "parallel_tool_calls": input["parallelToolCalls"] ?? true,
            "reasoning": input["reasoning"] ?? NSNull(),
            "store": input["store"] ?? false,
            "stream": input["stream"] ?? true,
            "include": input["include"] ?? [],
        ]
        if let instructions = input["instructions"] as? String, !instructions.isEmpty {
            request["instructions"] = instructions
        }
        if let metadata = input["metadata"] {
            request["client_metadata"] = metadata
        }
        if let serviceTier = input["serviceTier"] {
            request["service_tier"] = serviceTier
        }
        if let promptCacheKey = input["promptCacheKey"] {
            request["prompt_cache_key"] = promptCacheKey
        }
        if let text = input["text"] {
            request["text"] = text
        }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    private static func fallbackParseSSEEvent(_ data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "[DONE]" {
            return ["type": "done"]
        }
        let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let eventType = raw["type"] as? String
        switch eventType {
        case "response.output_text.delta":
            return ["type": "outputTextDelta", "delta": raw["delta"] as? String ?? "", "raw": raw]
        case "response.reasoning_summary_text.delta":
            return ["type": "reasoningSummaryDelta", "delta": raw["delta"] as? String ?? "", "raw": raw]
        case "response.function_call_arguments.delta":
            return [
                "type": "toolCallInputDelta",
                "delta": raw["delta"] as? String ?? "",
                "itemId": raw["item_id"] ?? NSNull(),
                "outputIndex": raw["output_index"] ?? NSNull(),
                "raw": raw,
            ]
        case "response.output_item.added":
            return ["type": "outputItemAdded", "item": raw["item"] ?? NSNull(), "raw": raw]
        case "response.output_item.done":
            return ["type": "outputItemDone", "item": raw["item"] ?? NSNull(), "raw": raw]
        case "response.completed":
            return ["type": "completed", "response": raw["response"] ?? NSNull(), "raw": raw]
        case "response.created":
            return ["type": "created", "raw": raw]
        case "error", "response.failed":
            return ["type": "error", "error": raw["error"] ?? raw, "raw": raw]
        default:
            return ["type": "raw", "eventType": eventType ?? "unknown", "raw": raw]
        }
    }

    private static func fallbackToolOutput(
        callID: String,
        output: Any,
        success: Bool,
        custom: Bool,
        name: String?
    ) -> [String: Any] {
        let payload = normalizeToolOutput(output, success: success)
        if custom {
            return [
                "type": "custom_tool_call_output",
                "call_id": callID,
                "name": name as Any,
                "output": payload,
            ]
        }
        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": payload,
        ]
    }

    private static func normalizeToolOutput(_ output: Any, success: Bool) -> String {
        let text: String
        if let output = output as? String {
            text = output
        } else if JSONSerialization.isValidJSONObject(output),
                  let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(describing: output)
        }
        return success ? text : "Tool failed:\n\(text)"
    }

    private static func fallbackEmulateShell(_ input: [String: Any]) -> [String: Any] {
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        return [
            "exit_code": 127,
            "stdout": "",
            "stderr": "\(command): shell emulator unavailable\n",
            "output": "\(command): shell emulator unavailable\n",
            "wall_time_seconds": 0,
            "truncated": false,
        ]
    }

    private static func fallbackApplyPatch(_ input: [String: Any]) -> [String: Any] {
        [
            "exit_code": 127,
            "stdout": "",
            "stderr": "apply_patch unavailable without CodexMobileCore artifact\n",
            "output": "apply_patch unavailable without CodexMobileCore artifact\n",
            "wall_time_seconds": 0,
            "truncated": false,
        ]
    }

    private static func fallbackRefreshTokenRequest(clientID: String, refreshToken: String) -> [String: Any] {
        [
            "path": "/oauth/token",
            "method": "POST",
            "headers": ["Content-Type": "application/json"],
            "body": [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ],
        ]
    }

    private static func fallbackAuthorizationURL(_ input: [String: Any]) -> [String: Any] {
        let issuer = (input["issuer"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: input["clientId"] as? String),
            URLQueryItem(name: "redirect_uri", value: input["redirectUri"] as? String),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: input["codeChallenge"] as? String),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: input["state"] as? String),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]
        return ["url": components?.url?.absoluteString ?? ""]
    }

    private static func fallbackAuthorizationCodeTokenRequest(_ input: [String: Any]) -> [String: Any] {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: input["code"] as? String),
            URLQueryItem(name: "redirect_uri", value: input["redirectUri"] as? String),
            URLQueryItem(name: "client_id", value: input["clientId"] as? String),
            URLQueryItem(name: "code_verifier", value: input["codeVerifier"] as? String),
        ]
        return [
            "path": "/oauth/token",
            "method": "POST",
            "headers": ["Content-Type": "application/x-www-form-urlencoded"],
            "body": components.percentEncodedQuery ?? "",
        ]
    }

    private static func fallbackParseChatGPTTokenClaims(token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw CodexMobileCoreBridgeError.invalidJWT
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: payload) else {
            throw CodexMobileCoreBridgeError.invalidJWT
        }
        let value = try decodeObject(data)
        let auth = value["https://api.openai.com/auth"] as? [String: Any]
        let profile = value["https://api.openai.com/profile"] as? [String: Any]
        let email = value["email"] as? String ?? profile?["email"] as? String
        let planType = auth?["chatgpt_plan_type"] as? String ?? value["chatgpt_plan_type"] as? String
        let userID = auth?["chatgpt_user_id"] as? String ?? auth?["user_id"] as? String ?? value["chatgpt_user_id"] as? String ?? value["user_id"] as? String
        let accountID = auth?["chatgpt_account_id"] as? String ?? value["chatgpt_account_id"] as? String ?? value["organization_id"] as? String
        return [
            "email": email ?? NSNull(),
            "chatgptPlanType": planType ?? NSNull(),
            "chatgptUserId": userID ?? NSNull(),
            "chatgptAccountId": accountID ?? NSNull(),
            "chatgptAccountIsFedramp": auth?["chatgpt_account_is_fedramp"] as? Bool ?? value["chatgpt_account_is_fedramp"] as? Bool ?? false,
            "expiresAt": value["exp"] ?? NSNull(),
        ]
    }

    private static func functionTool(
        name: String,
        description: String,
        required: [String],
        properties: [String: Any]
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw CodexMobileCoreBridgeError.missingField(field)
        }
        return value
    }

    #if canImport(CodexMobileCore)
    private typealias RustJSONFunction = (UnsafePointer<CChar>?) -> CodexMobileBuffer

    private static func rustObject(_ buffer: CodexMobileBuffer) throws -> [String: Any] {
        try decodeObject(rustBufferData(buffer))
    }

    private static func rustData(input: [String: Any], _ function: RustJSONFunction) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: input, options: [])
        let text = String(decoding: data, as: UTF8.self)
        return try rustData(input: text, function)
    }

    private static func rustData(input: String, _ function: RustJSONFunction) throws -> Data {
        let data = input.withCString { pointer in
            rustBufferData(function(pointer))
        }
        try throwIfRustError(data)
        return data
    }

    private static func rustBufferData(_ buffer: CodexMobileBuffer) -> Data {
        defer { codex_mobile_buffer_free(buffer) }
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            return Data()
        }
        return Data(bytes: pointer, count: Int(buffer.len))
    }

    private static func throwIfRustError(_ data: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == false
        else {
            return
        }
        throw CodexMobileCoreBridgeError.rustError(object["error"] as? String ?? "unknown Rust error")
    }
    #endif

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let object = object as? [String: Any] else {
            throw CodexMobileCoreBridgeError.invalidJSON
        }
        return object
    }
}

public enum CodexMobileCoreBridgeError: Error, Equatable {
    case missingField(String)
    case rustError(String)
    case invalidJSON
    case invalidJWT
    case invalidURL
}
