//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func subagentToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
        guard configuration.subagentOptions.isEnabled else {
            return []
        }

        func tool(
            _ name: String,
            _ description: String,
            _ properties: [String: [String: Any]],
            required: [String] = []
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

        let targetProperty: [String: Any] = [
            "type": "string",
            "description": "Agent id or canonical task name returned by spawn_agent.",
        ]
        let messageProperty: [String: Any] = [
            "type": "string",
            "description": "Plain-text message for the target agent.",
        ]
        let modelValues = Self.subagentModelOverrideValues(options: options)
        let reasoningEffortValues = Self.subagentReasoningEffortValues(options: options)
        let serviceTierValues = Self.subagentServiceTierValues(options: options)
        let roles = configuration.subagentOptions.roles
        let spawnAgentDescription = [
            "Spawn a child agent to work on the specified task. The child inherits the same workspace and tools and runs in the background.",
            Self.subagentRoleDescription(roles: roles),
            Self.subagentModelOverrideDescription(options: options),
            Self.subagentInheritedModelGuidance(options: options),
            "The default `fork_turns` is `all`. Full-history forked agents inherit the parent agent type, model, and reasoning effort; omit `agent_type`, `model`, and `reasoning_effort` unless `fork_turns` is `none` or a positive integer string.",
            "This session allows up to \(configuration.subagentOptions.maxOpenAgents) open subagents.",
            configuration.subagentOptions.maxDepth.map { "This session allows subagent nesting up to depth \($0), where direct children of `/root` are depth 1." } ?? "",
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return [
            tool(
                "spawn_agent",
                spawnAgentDescription,
                [
                    "task_name": [
                        "type": "string",
                        "description": "Task name for the new agent. Use lowercase letters, digits, and underscores.",
                    ],
                    "message": [
                        "type": "string",
                        "description": "Initial plain-text task for the new agent.",
                    ],
                    "agent_type": Self.schemaStringProperty(
                        description: "Optional type name for the new agent. If omitted, `default` is used.",
                        enumValues: roles.map(\.name)
                    ),
                    "fork_turns": [
                        "type": "string",
                        "description": "Optional history fork depth. Use none, all, or a positive integer string. Defaults to all.",
                    ],
                    "model": Self.schemaStringProperty(
                        description: "Optional model override. Omit to inherit the parent turn model. Only set when fork_turns is none or a positive integer string.",
                        enumValues: modelValues
                    ),
                    "reasoning_effort": Self.schemaStringProperty(
                        description: "Optional reasoning effort override. Omit to inherit the parent turn default. Only set when fork_turns is none or a positive integer string.",
                        enumValues: reasoningEffortValues
                    ),
                    "service_tier": Self.schemaStringProperty(
                        description: "Optional service tier override.",
                        enumValues: serviceTierValues
                    ),
                ],
                required: ["task_name", "message"]
            ),
            tool(
                "send_input",
                "Send input to an existing agent. Use interrupt=true to redirect a running agent immediately; otherwise input is queued or starts a new turn when the agent is idle.",
                [
                    "target": targetProperty,
                    "message": [
                        "type": "string",
                        "description": "Plain-text message to send. Use either message or items.",
                    ],
                    "items": [
                        "type": "array",
                        "description": "Optional structured input items. Text items are rendered into the message sent to the agent.",
                        "items": [
                            "type": "object",
                            "additionalProperties": true,
                        ],
                    ],
                    "interrupt": [
                        "type": "boolean",
                        "description": "True cancels the current task and handles this input immediately; false or omitted queues it.",
                    ],
                ],
                required: ["target"]
            ),
            tool(
                "send_message",
                "Send a message to an existing agent without triggering a new turn.",
                ["target": targetProperty, "message": messageProperty],
                required: ["target", "message"]
            ),
            tool(
                "resume_agent",
                "Resume a previously closed in-memory agent by id or task name so it can receive send_input and wait_agent calls.",
                [
                    "id": [
                        "type": "string",
                        "description": "Agent id or canonical task name to resume.",
                    ],
                ],
                required: ["id"]
            ),
            tool(
                "followup_task",
                "Send a follow-up task to an existing child agent and trigger a turn in that target.",
                ["target": targetProperty, "message": messageProperty],
                required: ["target", "message"]
            ),
            tool(
                "wait_agent",
                "Wait for an agent to finish or for any running child agent to produce a final status.",
                [
                    "target": targetProperty,
                    "timeout_ms": [
                        "type": "number",
                        "description": "Optional timeout in milliseconds.",
                    ],
                ]
            ),
            tool(
                "list_agents",
                "List live agents in this agent tree.",
                [
                    "path_prefix": [
                        "type": "string",
                        "description": "Optional absolute or current-agent-relative path prefix filter.",
                    ],
                ]
            ),
            tool(
                "close_agent",
                "Close an agent and cancel any running child turn.",
                ["target": targetProperty],
                required: ["target"]
            ),
        ]
    }
}
