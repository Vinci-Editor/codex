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
                name: "read_file",
                description: "Reads a UTF-8 text file from the active workspace without using shell.",
                required: ["path"],
                properties: [
                    "path": ["type": "string"],
                    "offset": ["type": "number"],
                    "limit": ["type": "number"],
                ]
            ),
            functionTool(
                name: "search_files",
                description: "Searches UTF-8 text files in the active workspace without using shell.",
                required: ["query"],
                properties: [
                    "query": ["type": "string"],
                    "path": ["type": "string"],
                    "case_sensitive": ["type": "boolean"],
                    "limit": ["type": "number"],
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
                name: "write_file",
                description: "Writes a complete UTF-8 text file in the active workspace. Prefer apply_patch for focused edits.",
                required: ["path", "content"],
                properties: [
                    "path": ["type": "string"],
                    "content": ["type": "string"],
                    "create_directories": ["type": "boolean"],
                ]
            ),
            functionTool(
                name: "view_image",
                description: "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.",
                required: ["path"],
                properties: [
                    "path": ["type": "string"],
                    "detail": [
                        "type": "string",
                        "enum": ["high", "original"],
                    ],
                ],
                outputSchema: [
                    "type": "object",
                    "properties": [
                        "image_url": ["type": "string"],
                        "detail": [
                            "type": "string",
                            "enum": ["high", "original"],
                        ],
                    ],
                    "required": ["image_url", "detail"],
                    "additionalProperties": false,
                ]
            ),
            functionTool(
                name: "update_plan",
                description: """
                Updates the task plan.
                Provide an optional explanation and a list of plan items, each with a step and status.
                At most one step can be in_progress at a time.
                """,
                required: ["plan"],
                properties: [
                    "explanation": [
                        "type": "string",
                        "description": "Optional explanation for this plan update.",
                    ],
                    "plan": [
                        "type": "array",
                        "description": "The list of steps",
                        "items": [
                            "type": "object",
                            "properties": [
                                "step": [
                                    "type": "string",
                                    "description": "Task step text.",
                                ],
                                "status": [
                                    "type": "string",
                                    "enum": ["pending", "in_progress", "completed"],
                                    "description": "Step status.",
                                ],
                            ],
                            "required": ["step", "status"],
                            "additionalProperties": false,
                        ],
                    ],
                ]
            ),
            functionTool(
                name: "shell_command",
                description: "Runs a one-shot shell command. On macOS this uses /bin/zsh; on iOS this is a deterministic Codex emulator.",
                required: ["command"],
                properties: [
                    "command": ["type": "string"],
                    "workdir": ["type": "string"],
                    "timeout_ms": ["type": "number"],
                    "max_output_tokens": ["type": "number"],
                    "max_output_bytes": ["type": "number"],
                    "login": [
                        "type": "boolean",
                        "description": "On macOS, true runs the command through a login shell. Defaults to true. On iOS this is accepted for compatibility.",
                    ],
                    "sandbox_permissions": [
                        "type": "string",
                        "enum": ["use_default", "require_escalated"],
                        "description": "Per-command sandbox override. Defaults to use_default; use require_escalated when the host app should ask for explicit approval before running.",
                    ],
                    "justification": [
                        "type": "string",
                        "description": "User-facing approval question for require_escalated; omit otherwise.",
                    ],
                    "prefix_rule": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Reusable session approval prefix for command, only with sandbox_permissions set to require_escalated; for example [\"git\", \"pull\"].",
                    ],
                ]
            ),
            functionTool(
                name: "exec_command",
                description: "Runs a one-shot shell command and returns Codex unified exec output. Ongoing session_id, write_stdin, and tty execution are not available in CodexKit.",
                required: ["cmd"],
                properties: [
                    "cmd": ["type": "string"],
                    "workdir": ["type": "string"],
                    "timeout_ms": ["type": "number"],
                    "yield_time_ms": ["type": "number"],
                    "max_output_tokens": ["type": "number"],
                    "max_output_bytes": ["type": "number"],
                    "login": [
                        "type": "boolean",
                        "description": "On macOS, true runs the command through a login shell. Defaults to true. On iOS this is accepted for compatibility.",
                    ],
                    "sandbox_permissions": [
                        "type": "string",
                        "enum": ["use_default", "require_escalated"],
                        "description": "Per-command sandbox override. Defaults to use_default; use require_escalated when the host app should ask for explicit approval before running.",
                    ],
                    "justification": [
                        "type": "string",
                        "description": "User-facing approval question for require_escalated; omit otherwise.",
                    ],
                    "prefix_rule": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Reusable session approval prefix for cmd, only with sandbox_permissions set to require_escalated; for example [\"git\", \"pull\"].",
                    ],
                ]
            ),
        ]
    }

    private static func mergedBuiltinTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        var merged = tools
        var names = Set(tools.compactMap { $0["name"] as? String })

        for tool in fallbackBuiltinTools() {
            guard let name = tool["name"] as? String, !names.contains(name) else {
                continue
            }
            merged.append(tool)
            names.insert(name)
        }

        return merged
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
            return [
                "type": "outputTextDelta",
                "delta": raw["delta"] as? String ?? "",
                "itemId": raw["item_id"] ?? raw["itemId"] ?? NSNull(),
                "raw": raw,
            ]
        case "response.reasoning_summary_text.delta":
            return [
                "type": "reasoningSummaryDelta",
                "delta": raw["delta"] as? String ?? "",
                "itemId": raw["item_id"] ?? raw["itemId"] ?? NSNull(),
                "raw": raw,
            ]
        case "response.function_call_arguments.delta", "response.tool_call_input.delta":
            return [
                "type": "toolCallInputDelta",
                "delta": raw["delta"] as? String ?? "",
                "itemId": raw["item_id"] ?? NSNull(),
                "callId": raw["call_id"] ?? raw["callId"] ?? NSNull(),
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

    private static func normalizeToolOutput(_ output: Any, success: Bool) -> Any {
        if success, isToolOutputContentItems(output) {
            return output
        }
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

    private static func isToolOutputContentItems(_ output: Any) -> Bool {
        guard let items = output as? [[String: Any]], !items.isEmpty else {
            return false
        }
        return items.allSatisfy { item in
            guard let type = item["type"] as? String else {
                return false
            }
            switch type {
            case "input_text":
                return item["text"] is String
            case "input_image":
                return item["image_url"] is String
            default:
                return false
            }
        }
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

    private static func shellOutputLimit(_ input: [String: Any]) -> Int {
        max(1, intValue(input["maxOutputBytes"])
            ?? intValue(input["max_output_bytes"])
            ?? intValue(input["max_output_tokens"]).map { $0 * 4 }
            ?? 64 * 1024)
    }

    private static func shellWorkspaceRoot(_ input: [String: Any]) throws -> URL {
        let rootPath = input["workspaceRoot"] as? String
            ?? input["workspace_root"] as? String
            ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: root.path,
                NSLocalizedDescriptionKey: "\(root.path): no such directory",
            ])
        }
        return root
    }

    private static func shellWorkingDirectory(_ input: [String: Any]) throws -> URL {
        let root = try shellWorkspaceRoot(input)
        let rawWorkdir = input["workdir"] as? String ?? input["cwd"] as? String ?? ""
        let candidate = rawWorkdir.isEmpty
            ? root
            : rawWorkdir.hasPrefix("/")
                ? URL(fileURLWithPath: rawWorkdir)
                : root.appending(path: rawWorkdir, directoryHint: .isDirectory)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: resolved.path,
                NSLocalizedDescriptionKey: "\(resolved.path): escapes workspace",
            ])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: resolved.path,
                NSLocalizedDescriptionKey: "\(resolved.path): no such directory",
            ])
        }
        return resolved
    }

    private static func virtualShellWorkingDirectory(root: URL, workdir: URL) -> String {
        let rootPath = root.path
        let workdirPath = workdir.path
        guard workdirPath != rootPath else {
            return "/"
        }
        let relativePath = workdirPath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relativePath.isEmpty ? "/" : "/\(relativePath)"
    }

    private static func shellResponse(
        exitCode: Int,
        stdout: String,
        stderr: String,
        started: Date,
        truncated: Bool
    ) -> [String: Any] {
        let output: String
        if stderr.isEmpty {
            output = stdout
        } else if stdout.isEmpty {
            output = stderr
        } else {
            output = stdout + stderr
        }
        return [
            "exit_code": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "output": output,
            "wall_time_seconds": Date().timeIntervalSince(started),
            "truncated": truncated,
        ]
    }

    private static func limitedShellText(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let collector = ShellOutputCollector(maxBytes: maxBytes)
        collector.append(Data(text.utf8))
        return (collector.string(), collector.wasTruncated)
    }

    private final class ShellOutputCollector: @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        var wasTruncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return truncated
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else {
                return
            }
            lock.lock()
            defer { lock.unlock() }

            let remaining = maxBytes - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            let wasTruncated = truncated
            lock.unlock()

            var text = String(decoding: snapshot, as: UTF8.self)
            if wasTruncated {
                text += "\n[output truncated]\n"
            }
            return text
        }
    }

    #if os(macOS)
    private static func runNativeShell(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)?
    ) -> [String: Any] {
        let started = Date()
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return shellResponse(
                exitCode: 64,
                stdout: "",
                stderr: "Missing command.\n",
                started: started,
                truncated: false
            )
        }

        let maxOutputBytes = shellOutputLimit(input)
        let timeoutMilliseconds = max(1, intValue(input["timeout_ms"]) ?? 120_000)
        let useLoginShell = input["login"] as? Bool ?? true

        let workdir: URL
        do {
            workdir = try shellWorkingDirectory(input)
        } catch {
            return shellResponse(
                exitCode: 1,
                stdout: "",
                stderr: "\(error.localizedDescription)\n",
                started: started,
                truncated: false
            )
        }

        let stdout = ShellOutputCollector(maxBytes: maxOutputBytes)
        let stderr = ShellOutputCollector(maxBytes: maxOutputBytes)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stdout.append(data)
            if !data.isEmpty {
                outputHandler?(String(decoding: data, as: UTF8.self))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stderr.append(data)
            if !data.isEmpty {
                outputHandler?(String(decoding: data, as: UTF8.self))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = useLoginShell ? ["-lc", command] : ["-c", command]
        process.currentDirectoryURL = workdir
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return shellResponse(
                exitCode: 126,
                stdout: "",
                stderr: "\(error.localizedDescription)\n",
                started: started,
                truncated: false
            )
        }

        var timedOut = false
        if termination.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            timedOut = true
            process.terminate()
            if termination.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + .seconds(1))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stdout.append(remainingStdout)
        if !remainingStdout.isEmpty {
            outputHandler?(String(decoding: remainingStdout, as: UTF8.self))
        }
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stderr.append(remainingStderr)
        if !remainingStderr.isEmpty {
            outputHandler?(String(decoding: remainingStderr, as: UTF8.self))
        }

        if timedOut {
            let timeoutData = Data("Command timed out after \(timeoutMilliseconds) ms.\n".utf8)
            stderr.append(timeoutData)
            outputHandler?(String(decoding: timeoutData, as: UTF8.self))
        }

        return shellResponse(
            exitCode: timedOut ? 124 : Int(process.terminationStatus),
            stdout: stdout.string(),
            stderr: stderr.string(),
            started: started,
            truncated: stdout.wasTruncated || stderr.wasTruncated
        )
    }
    #endif

    #if canImport(JustBash) && canImport(JustBashFS)
    private static func runJustBashShell(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)?
    ) async -> [String: Any] {
        let started = Date()
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return shellResponse(
                exitCode: 64,
                stdout: "",
                stderr: "Missing command.\n",
                started: started,
                truncated: false
            )
        }

        let maxOutputBytes = shellOutputLimit(input)
        let timeoutMilliseconds = max(1, intValue(input["timeout_ms"]) ?? 120_000)

        let root: URL
        let workdir: URL
        do {
            root = try shellWorkspaceRoot(input)
            workdir = try shellWorkingDirectory(input)
        } catch {
            return shellResponse(
                exitCode: 1,
                stdout: "",
                stderr: "\(error.localizedDescription)\n",
                started: started,
                truncated: false
            )
        }

        let cwd = virtualShellWorkingDirectory(root: root, workdir: workdir)
        let fileSystem = CodexJailedBashFileSystem(rootURL: root)
        let executionLimits = ExecutionLimits(
            maxInputLength: max(256_000, command.utf8.count + 1024),
            maxTokenCount: 16_000,
            maxCommandCount: 10_000,
            maxOutputLength: max(1_048_576, maxOutputBytes * 2),
            maxPipelineLength: 64,
            maxCallDepth: 100,
            maxLoopIterations: 10_000,
            maxSubstitutionDepth: 50
        )
        let bash = Bash(options: BashOptions(
            env: [
                "HOME": "/",
                "USER": "coder",
                "LOGNAME": "coder",
                "PWD": cwd,
                "OLDPWD": cwd,
                "TMPDIR": cwd,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/bash",
                "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8",
            ],
            cwd: cwd,
            executionLimits: executionLimits,
            customCommands: justBashHostCompatibilityCommands(),
            filesystem: fileSystem,
            allowedURLPrefixes: [],
            embeddedRuntimes: justBashEmbeddedRuntimes()
        ))
        await seedJailedCommandStubs(from: bash, into: fileSystem)

        let outcome = await runJustBash(command: command, bash: bash, timeoutMilliseconds: timeoutMilliseconds)
        let exitCode: Int
        let rawStdout: String
        let rawStderr: String
        switch outcome {
        case .completed(let result):
            exitCode = result.exitCode
            rawStdout = result.stdout
            rawStderr = result.stderr
        case .timedOut:
            exitCode = 124
            rawStdout = ""
            rawStderr = "Command timed out after \(timeoutMilliseconds) ms.\n"
        }

        let stdout = limitedShellText(rawStdout, maxBytes: maxOutputBytes)
        let stderr = limitedShellText(rawStderr, maxBytes: maxOutputBytes)
        let response = shellResponse(
            exitCode: exitCode,
            stdout: stdout.text,
            stderr: stderr.text,
            started: started,
            truncated: stdout.truncated || stderr.truncated
        )
        if let output = response["output"] as? String, !output.isEmpty {
            outputHandler?(output)
        }
        return response
    }

    private enum JustBashExecutionOutcome: Sendable {
        case completed(ExecResult)
        case timedOut
    }

    private final class JustBashExecutionRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<JustBashExecutionOutcome, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<JustBashExecutionOutcome, Never>) {
            self.continuation = continuation
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            let shouldCancel: Bool
            lock.lock()
            if continuation == nil {
                shouldCancel = true
            } else {
                timeoutTask = task
                shouldCancel = false
            }
            lock.unlock()

            if shouldCancel {
                task.cancel()
            }
        }

        func finish(_ outcome: JustBashExecutionOutcome) {
            let continuationToResume: CheckedContinuation<JustBashExecutionOutcome, Never>?
            let timeoutTaskToCancel: Task<Void, Never>?
            lock.lock()
            continuationToResume = continuation
            continuation = nil
            timeoutTaskToCancel = timeoutTask
            timeoutTask = nil
            lock.unlock()

            timeoutTaskToCancel?.cancel()
            continuationToResume?.resume(returning: outcome)
        }
    }

    private static func runJustBash(
        command: String,
        bash: Bash,
        timeoutMilliseconds: Int
    ) async -> JustBashExecutionOutcome {
        await withCheckedContinuation { continuation in
            let race = JustBashExecutionRace(continuation)
            let execTask = Task {
                let result = await bash.exec(command)
                race.finish(.completed(result))
            }
            let timeoutTask = Task {
                let timeout = UInt64(min(timeoutMilliseconds, 3_600_000)) * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: timeout)
                } catch {
                    return
                }
                execTask.cancel()
                race.finish(.timedOut)
            }
            race.setTimeoutTask(timeoutTask)
        }
    }

    static func emulatePortableShellForTesting(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) async -> [String: Any] {
        await runJustBashShell(input, outputHandler: outputHandler)
    }

    private static func seedJailedCommandStubs(from bash: Bash, into fileSystem: CodexJailedBashFileSystem) async {
        let names = await bash.commandNames
        for name in names where !name.contains("/") {
            fileSystem.seedCommandStub(named: name)
        }
        for name in justBashShellBuiltinNames {
            fileSystem.seedCommandStub(named: name)
        }
    }

    private static func justBashHostCompatibilityCommands() -> [AnyBashCommand] {
        var commands = [
            justBashShellLauncherCommand(named: "sh"),
            justBashShellLauncherCommand(named: "bash"),
            justBashShellLauncherCommand(named: "/bin/sh"),
            justBashShellLauncherCommand(named: "/bin/bash"),
            justBashShellLauncherCommand(named: "/usr/bin/bash"),
            justBashEnvCommand(named: "/usr/bin/env"),
            justBashEnvCommand(named: "/bin/env"),
            justBashNodeCommand(named: "node"),
            justBashNodeCommand(named: "/bin/node"),
            justBashNodeCommand(named: "/usr/bin/node"),
        ]
        var seen = Set(commands.map(\.name))
        for name in justBashPathAliasCommandNames {
            for prefix in ["/bin/", "/usr/bin/"] {
                let alias = "\(prefix)\(name)"
                guard seen.insert(alias).inserted else {
                    continue
                }
                commands.append(justBashPathAliasCommand(named: alias, targetName: name))
            }
        }
        return commands
    }

    private static func justBashEmbeddedRuntimes() -> [any EmbeddedRuntime] {
        #if canImport(JustBashJavaScript)
        return [JavaScriptRuntime()]
        #else
        return []
        #endif
    }

    private static func justBashPathAliasCommand(named alias: String, targetName: String) -> AnyBashCommand {
        AnyBashCommand(name: alias) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(alias): shell execution unavailable", exitCode: 126)
            }
            let script = ([targetName] + args).map(shellQuoteForJustBash).joined(separator: " ")
            return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
        }
    }

    private static func justBashShellLauncherCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            switch shellLauncherScript(from: args, context: context, commandName: name) {
            case .script(let script):
                guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ExecResult.success()
                }
                return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
            case .result(let result):
                return result
            }
        }
    }

    private static func justBashEnvCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            let parsed = envCommandScriptArguments(args)
            guard parsed.isSupported else {
                return ExecResult.failure("\(name): unsupported option", exitCode: 125)
            }
            let environment = parsed.ignoreExistingEnvironment
                ? parsed.environment
                : context.environment.merging(parsed.environment, uniquingKeysWith: { _, new in new })
            guard !parsed.commandArguments.isEmpty else {
                let output = environment.keys
                    .sorted()
                    .map { "\($0)=\(environment[$0] ?? "")" }
                    .joined(separator: "\n")
                return ExecResult.success(output + (output.isEmpty ? "" : "\n"))
            }

            let commandScript = parsed.commandArguments.map(shellQuoteForJustBash).joined(separator: " ")
            return await executeSubshell(scriptWithInheritedEnvironment(commandScript, environment: environment))
        }
    }

    private static func justBashNodeCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            switch nodeJSExecArguments(from: args, stdin: context.stdin, commandName: name) {
            case .arguments(let jsExecArguments):
                let script = (["js-exec"] + jsExecArguments).map(shellQuoteForJustBash).joined(separator: " ")
                return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
            case .result(let result):
                return result
            }
        }
    }

    private static func nodeJSExecArguments(
        from args: [String],
        stdin: String,
        commandName: String
    ) -> NodeLauncherResolution {
        guard !args.isEmpty else {
            return stdin.isEmpty ? .arguments(["-c", ""]) : .arguments(["-c", stdin])
        }

        var isModule = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }

            switch argument {
            case "-v", "--version":
                return .result(ExecResult.success("v20.0.0-justbash\n"))
            case "-h", "--help":
                return .result(ExecResult.success("""
                Usage: node [options] [script.js] [arguments]

                iOS Codex routes node-compatible JavaScript through JustBashJavaScript.
                Supported: -e/--eval, -p/--print, --input-type=module, script files.

                """))
            case "-e", "--eval":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): \(argument) requires an argument", exitCode: 2))
                }
                var jsExecArguments = isModule ? ["-m"] : []
                jsExecArguments += ["-c", args[index + 1]]
                jsExecArguments += Array(args.dropFirst(index + 2))
                return .arguments(jsExecArguments)
            case "-p", "--print":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): \(argument) requires an argument", exitCode: 2))
                }
                var jsExecArguments = isModule ? ["-m"] : []
                jsExecArguments += ["-c", "console.log(\(args[index + 1]));"]
                jsExecArguments += Array(args.dropFirst(index + 2))
                return .arguments(jsExecArguments)
            case "--input-type=module", "--experimental-modules":
                isModule = true
                index += 1
                continue
            case "--input-type=commonjs", "--no-warnings", "--enable-source-maps", "--trace-warnings":
                index += 1
                continue
            case "--input-type":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): --input-type requires an argument", exitCode: 2))
                }
                let value = args[index + 1]
                if value == "module" {
                    isModule = true
                } else if value != "commonjs" {
                    return .result(ExecResult.failure("\(commandName): unsupported --input-type=\(value)", exitCode: 2))
                }
                index += 2
                continue
            case "-":
                return stdin.isEmpty ? .arguments(isModule ? ["-m", "-c", ""] : ["-c", ""]) : .arguments(isModule ? ["-m", "-c", stdin] : ["-c", stdin])
            default:
                if argument.hasPrefix("-") {
                    return .result(ExecResult.failure("\(commandName): unsupported option \(argument)", exitCode: 125))
                }
            }
            break
        }

        guard index < args.count else {
            return stdin.isEmpty ? .arguments(isModule ? ["-m", "-c", ""] : ["-c", ""]) : .arguments(isModule ? ["-m", "-c", stdin] : ["-c", stdin])
        }

        var jsExecArguments = isModule ? ["-m"] : []
        jsExecArguments.append(args[index])
        jsExecArguments += Array(args.dropFirst(index + 1))
        return .arguments(jsExecArguments)
    }

    private enum NodeLauncherResolution {
        case arguments([String])
        case result(ExecResult)
    }

    private static func shellLauncherScript(
        from args: [String],
        context: CommandContext,
        commandName: String
    ) -> ShellLauncherResolution {
        guard !args.isEmpty else {
            return .script("")
        }

        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }
            if argument == "-c" || (argument.hasPrefix("-") && argument.dropFirst().contains("c")) {
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): option requires an argument -- c", exitCode: 2))
                }
                return .script(args[index + 1])
            }
            guard argument.hasPrefix("-") else {
                break
            }
            index += 1
        }

        guard index < args.count else {
            return .script("")
        }

        let scriptPath = args[index]
        do {
            let data = try context.fileSystem.readFile(path: scriptPath, relativeTo: context.cwd)
            return .script(String(decoding: data, as: UTF8.self))
        } catch {
            return .result(ExecResult.failure("\(commandName): \(scriptPath): \(error.localizedDescription)", exitCode: 127))
        }
    }

    private enum ShellLauncherResolution {
        case script(String)
        case result(ExecResult)
    }

    private static func envCommandScriptArguments(_ args: [String]) -> (
        environment: [String: String],
        commandArguments: [String],
        ignoreExistingEnvironment: Bool,
        isSupported: Bool
    ) {
        var environment: [String: String] = [:]
        var ignoreExistingEnvironment = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "-i", "--ignore-environment":
                ignoreExistingEnvironment = true
                index += 1
                continue
            case "-S":
                guard index + 1 < args.count else {
                    return (environment, [], ignoreExistingEnvironment, false)
                }
                let split = args[index + 1].split(separator: " ").map(String.init)
                return (environment, split + Array(args.dropFirst(index + 2)), ignoreExistingEnvironment, true)
            default:
                if argument.hasPrefix("-") {
                    return (environment, [], ignoreExistingEnvironment, false)
                }
                if let assignmentRange = argument.range(of: "="),
                   assignmentRange.lowerBound != argument.startIndex
                {
                    let key = String(argument[..<assignmentRange.lowerBound])
                    let value = String(argument[assignmentRange.upperBound...])
                    environment[key] = value
                    index += 1
                    continue
                }
                return (environment, Array(args.dropFirst(index)), ignoreExistingEnvironment, true)
            }
        }
        return (environment, [], ignoreExistingEnvironment, true)
    }

    private static func scriptWithInheritedEnvironment(_ script: String, environment: [String: String]) -> String {
        let exports = environment
            .filter { key, _ in isShellIdentifier(key) }
            .map { key, value in
                "export \(key)=\(shellQuoteForJustBash(value))"
            }
            .sorted()
            .joined(separator: "\n")
        return exports.isEmpty ? script : "\(exports)\n\(script)"
    }

    private static func isShellIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_").contains(first)
        else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains(scalar)
        }
    }

    private static func shellQuoteForJustBash(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        if value.unicodeScalars.allSatisfy({ scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
                .contains(scalar)
        }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let justBashShellBuiltinNames = [
        ":", ".", "[", "alias", "break", "builtin", "cd", "command", "compgen",
        "complete", "compopt", "continue", "declare", "dirs", "echo", "eval",
        "exec", "exit", "export", "false", "getopts", "hash", "let", "local",
        "mapfile", "popd", "printf", "pushd", "pwd", "read", "readarray",
        "readonly", "return", "set", "shift", "shopt", "source", "test",
        "trap", "true", "type", "typeset", "unalias", "unset", "which",
    ]

    private static let justBashPathAliasCommandNames = [
        "awk", "base64", "basename", "bash", "bc", "bunzip2", "bzcat", "bzip2",
        "cat", "chmod", "chronic", "cksum", "clear", "column", "combine",
        "comm", "cp", "curl", "cut", "date", "df", "diff", "dirname", "du",
        "egrep", "env", "errno", "expr", "expand", "fgrep", "file", "find",
        "fmt", "fold", "free", "getconf", "git", "grep", "gunzip", "gzip",
        "head", "help", "hexdump", "history", "hostname", "htmlToMarkdown",
        "iconv", "ifdata", "join", "jot", "jq", "kill", "killall", "ln",
        "look", "ls", "md5sum", "mkdir", "mktemp", "mv", "nl", "nproc", "od",
        "paste", "pathchk", "pee", "pr", "ps", "readlink", "realpath", "rev",
        "rg", "rm", "rmdir", "sed", "seq", "sh", "sha1sum", "sha256sum", "shuf",
        "sleep", "sort", "sponge", "split", "sqlite3", "stat", "strings", "sum",
        "tac", "tail", "tar", "tee", "time", "timeout", "touch", "tput", "tr",
        "tree", "ts", "tsort", "tty", "uname", "unexpand", "uniq", "unzip",
        "uptime", "uuencode", "vidir", "vipe", "wc", "whereis", "which",
        "whoami", "xan", "xargs", "xxd", "yes", "yq", "zcat", "zip",
    ]

    private final class CodexJailedBashFileSystem: @unchecked Sendable, BashFilesystem {
        private let rootURL: URL
        private let rootPath: String
        private let fileManager = FileManager.default
        private let lock = NSLock()
        private var commandStubs = Set<String>()

        init(rootURL: URL) {
            self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            self.rootPath = self.rootURL.path
        }

        func seedCommandStub(named name: String) {
            lock.lock()
            commandStubs.insert("/bin/\(name)")
            commandStubs.insert("/usr/bin/\(name)")
            lock.unlock()
        }

        func readFile(path: String, relativeTo: String) throws -> Data {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return Data()
            }
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind != .directory else {
                throw FilesystemError.isDirectory(normalized)
            }
            let url = try urlForExistingPath(normalized)
            do {
                return try Data(contentsOf: url)
            } catch {
                throw FilesystemError.ioError("cannot read \(normalized): \(error.localizedDescription)")
            }
        }

        func writeFile(path: String, content: Data, relativeTo: String) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            if fileExists(path: normalized, relativeTo: "/") {
                let info = try fileInfo(path: normalized, relativeTo: "/")
                guard info.kind != .directory else {
                    throw FilesystemError.isDirectory(normalized)
                }
                _ = try urlForExistingPath(normalized)
            }
            try ensureWritableParent(for: normalized)
            let url = try url(forNormalizedPath: normalized)
            do {
                try content.write(to: url)
            } catch {
                throw FilesystemError.ioError("cannot write \(normalized): \(error.localizedDescription)")
            }
        }

        func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard normalized != "/" else {
                throw FilesystemError.invalidPath(normalized)
            }
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            guard fileExists(path: normalized, relativeTo: "/") else {
                if force {
                    return
                }
                throw FilesystemError.notFound(normalized)
            }
            let info = try fileInfo(path: normalized, relativeTo: "/")
            if info.kind == .directory && !recursive {
                let entries = try listDirectory(path: normalized, relativeTo: "/")
                if !entries.isEmpty {
                    throw FilesystemError.directoryNotEmpty(normalized)
                }
            }
            let url = try urlForExistingPath(normalized)
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw FilesystemError.ioError("cannot delete \(normalized): \(error.localizedDescription)")
            }
        }

        func fileExists(path: String, relativeTo: String) -> Bool {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return true
            }
            guard let url = try? url(forNormalizedPath: normalized) else {
                return false
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return false
            }
            return (try? ensureResolvedURLIsInsideJail(url, normalizedPath: normalized)) != nil
        }

        func isDirectory(path: String, relativeTo: String) -> Bool {
            (try? fileInfo(path: path, relativeTo: relativeTo).kind) == .directory
        }

        func listDirectory(path: String, relativeTo: String) throws -> [String] {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind == .directory else {
                throw FilesystemError.notDirectory(normalized)
            }
            let url = try urlForExistingPath(normalized)
            do {
                return try fileManager.contentsOfDirectory(atPath: url.path).sorted()
            } catch {
                throw FilesystemError.ioError("cannot list \(normalized): \(error.localizedDescription)")
            }
        }

        func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard normalized != "/" else {
                return
            }
            if fileExists(path: normalized, relativeTo: "/") {
                guard isDirectory(path: normalized, relativeTo: "/") else {
                    throw FilesystemError.notDirectory(normalized)
                }
                return
            }
            if recursive {
                try ensureNearestExistingAncestorIsInsideJail(for: normalized)
            } else {
                try ensureWritableParent(for: normalized)
            }
            let url = try url(forNormalizedPath: normalized)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
            } catch {
                throw FilesystemError.ioError("cannot create directory \(normalized): \(error.localizedDescription)")
            }
        }

        func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return FileInfo(path: normalized, kind: .file, size: 0)
            }
            let url = try url(forNormalizedPath: normalized)
            guard fileManager.fileExists(atPath: url.path) else {
                throw FilesystemError.notFound(normalized)
            }
            _ = try ensureResolvedURLIsInsideJail(url, normalizedPath: normalized)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                return FileInfo(path: normalized, kind: .symlink, size: target.utf8.count)
            }
            if values.isDirectory == true {
                let count = (try? fileManager.contentsOfDirectory(atPath: url.path).count) ?? 0
                return FileInfo(path: normalized, kind: .directory, size: count)
            }
            return FileInfo(path: normalized, kind: .file, size: values.fileSize ?? 0)
        }

        func createSymlink(_ target: String, at path: String, relativeTo: String) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            try ensureWritableParent(for: normalized)
            let url = try url(forNormalizedPath: normalized)
            let hostTarget: String
            if target.hasPrefix("/") {
                hostTarget = try self.url(forNormalizedPath: normalizePath(target, relativeTo: "/")).path
            } else {
                hostTarget = target
            }
            do {
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: hostTarget)
            } catch {
                throw FilesystemError.ioError("cannot create symlink \(normalized): \(error.localizedDescription)")
            }
        }

        func readlink(_ path: String, relativeTo: String) throws -> String {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.invalidPath(normalized)
            }
            let url = try url(forNormalizedPath: normalized)
            guard fileManager.fileExists(atPath: url.path) else {
                throw FilesystemError.notFound(normalized)
            }
            do {
                let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                guard target.hasPrefix(rootPath + "/") || target == rootPath else {
                    return target
                }
                let relative = target.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? "/" : "/\(relative)"
            } catch {
                throw FilesystemError.ioError("cannot readlink \(normalized): \(error.localizedDescription)")
            }
        }

        func walk(path: String, relativeTo: String) throws -> [String] {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind == .directory else {
                return [normalized]
            }
            var result = [normalized]
            for name in try listDirectory(path: normalized, relativeTo: "/") {
                let child = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
                result.append(contentsOf: try walk(path: child, relativeTo: "/"))
            }
            return result
        }

        func normalizePath(_ path: String, relativeTo: String) -> String {
            VirtualPath.normalize(path, relativeTo: relativeTo)
        }

        func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
            let normalizedPattern = VirtualPath.normalize(pattern, relativeTo: relativeTo)
            let components = normalizedPattern.split(separator: "/").map(String.init)
            guard !components.isEmpty else {
                return fileExists(path: "/", relativeTo: "/") ? ["/"] : []
            }

            var results: [String] = []
            func descend(path: String, remaining: ArraySlice<String>) {
                guard let segment = remaining.first else {
                    if fileExists(path: path, relativeTo: "/") {
                        results.append(path)
                    }
                    return
                }

                guard isDirectory(path: path, relativeTo: "/") else {
                    return
                }

                if !segment.contains("*") && !segment.contains("?") && !segment.contains("[") {
                    let child = path == "/" ? "/\(segment)" : "\(path)/\(segment)"
                    descend(path: child, remaining: remaining.dropFirst())
                    return
                }

                guard let entries = try? listDirectory(path: path, relativeTo: "/") else {
                    return
                }
                for name in entries {
                    if !dotglob && !segment.hasPrefix(".") && name.hasPrefix(".") {
                        continue
                    }
                    if VirtualFileSystem.globMatch(name: name, pattern: segment, extglob: extglob) {
                        let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
                        descend(path: child, remaining: remaining.dropFirst())
                    }
                }
            }

            descend(path: "/", remaining: ArraySlice(components))
            return Array(Set(results)).sorted()
        }

        private func isCommandStub(_ normalizedPath: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return commandStubs.contains(normalizedPath)
        }

        private func url(forNormalizedPath normalizedPath: String) throws -> URL {
            let normalizedPath = VirtualPath.normalize(normalizedPath, relativeTo: "/")
            let url = normalizedPath == "/"
                ? rootURL
                : rootURL.appendingPathComponent(String(normalizedPath.dropFirst()))
            let standardized = url.standardizedFileURL
            guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
                throw FilesystemError.permissionDenied(normalizedPath)
            }
            return standardized
        }

        private func urlForExistingPath(_ normalizedPath: String) throws -> URL {
            let url = try url(forNormalizedPath: normalizedPath)
            _ = try ensureResolvedURLIsInsideJail(url, normalizedPath: normalizedPath)
            return url
        }

        private func ensureResolvedURLIsInsideJail(_ url: URL, normalizedPath: String) throws -> URL {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
                throw FilesystemError.permissionDenied(normalizedPath)
            }
            return resolved
        }

        private func ensureWritableParent(for normalizedPath: String) throws {
            let parent = VirtualPath.dirname(normalizedPath)
            guard isDirectory(path: parent, relativeTo: "/") else {
                throw FilesystemError.notFound(parent)
            }
            let parentURL = try url(forNormalizedPath: parent)
            _ = try ensureResolvedURLIsInsideJail(parentURL, normalizedPath: parent)
        }

        private func ensureNearestExistingAncestorIsInsideJail(for normalizedPath: String) throws {
            var ancestor = VirtualPath.dirname(normalizedPath)
            while ancestor != "/" && !fileExists(path: ancestor, relativeTo: "/") {
                ancestor = VirtualPath.dirname(ancestor)
            }
            guard isDirectory(path: ancestor, relativeTo: "/") else {
                throw FilesystemError.notDirectory(ancestor)
            }
            let ancestorURL = try url(forNormalizedPath: ancestor)
            _ = try ensureResolvedURLIsInsideJail(ancestorURL, normalizedPath: ancestor)
        }
    }
    #endif

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
        let body = formEncoded([
            ("grant_type", "authorization_code"),
            ("code", input["code"] as? String),
            ("redirect_uri", input["redirectUri"] as? String),
            ("client_id", input["clientId"] as? String),
            ("code_verifier", input["codeVerifier"] as? String),
        ])
        return [
            "path": "/oauth/token",
            "method": "POST",
            "headers": ["Content-Type": "application/x-www-form-urlencoded"],
            "body": body,
        ]
    }

    private static func formEncoded(_ pairs: [(String, String?)]) -> String {
        pairs.map { key, value in
            "\(formPercentEncoded(key))=\(formPercentEncoded(value ?? ""))"
        }
        .joined(separator: "&")
    }

    private static func formPercentEncoded(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var encoded = ""
        for byte in value.utf8 {
            if allowed.contains(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
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

    private static func fallbackDeviceKeySigningPayload(_ payload: [String: Any]) throws -> Data {
        let signedPayload: [String: Any] = [
            "domain": "codex-device-key-sign-payload/v1",
            "payload": payload,
        ]
        if #available(iOS 13.0, macOS 10.15, *) {
            return try JSONSerialization.data(
                withJSONObject: signedPayload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        return try JSONSerialization.data(withJSONObject: signedPayload, options: [.sortedKeys])
    }

    private static func functionTool(
        name: String,
        description: String,
        required: [String],
        properties: [String: Any],
        outputSchema: [String: Any]? = nil
    ) -> [String: Any] {
        var tool: [String: Any] = [
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
        if let outputSchema {
            tool["output_schema"] = outputSchema
        }
        return tool
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw CodexMobileCoreBridgeError.missingField(field)
        }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
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
