//
//  EchoTool.swift
//  CodexMobileDemo
//
//  Created by Ethan Lipnik.
//

import CodexKit

struct EchoTool: CodexTool {
    let name = "echo_demo"
    let description = "Echoes the provided text."
    let inputSchema: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "text": ["type": "string"],
        ],
        "required": ["text"],
        "additionalProperties": false,
    ]

    func execute(call: CodexToolCall, context: CodexToolContext) async throws -> CodexToolResult {
        CodexToolResult(output: call.arguments)
    }
}
