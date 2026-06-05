//
//  Created by Ethan Lipnik
//

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

extension CodexMobileCoreBridge {
    static func fallbackVersion() -> [String: Any] {
        [
            "crate": "codex-mobile-core",
            "version": "0.0.0",
            "abi": 1,
            "source": "swift-fallback",
        ]
    }

    static func fallbackProviderDefaults() -> [[String: Any]] {
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

    static func fallbackBuiltinTools() -> [[String: Any]] {
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

    static func mergedBuiltinTools(_ tools: [[String: Any]]) -> [[String: Any]] {
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

    static func fallbackBuildResponsesRequest(_ input: [String: Any]) throws -> Data {
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

    static func fallbackParseSSEEvent(_ data: Data) throws -> [String: Any] {
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

    static func fallbackToolOutput(
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

    static func normalizeToolOutput(_ output: Any, success: Bool) -> Any {
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

    static func isToolOutputContentItems(_ output: Any) -> Bool {
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
}
