//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func executeTool(
        _ call: CodexToolCall,
        progress: CodexToolProgressHandler? = nil,
        subagentStatus: CodexSubagentStatusHandler? = nil,
        subagentEvent: CodexSubagentEventHandler? = nil
    ) async throws -> CodexToolResult {
        if let deniedResult = await deniedToolResultIfNeeded(for: call) {
            return deniedResult
        }

        if let tool = toolsByName[call.name] {
            if let streamingTool = tool as? any CodexStreamingTool {
                return try await streamingTool.execute(
                    call: call,
                    context: CodexToolContext(workspace: configuration.workspace),
                    progress: progress
                )
            }
            return try await tool.execute(
                call: call,
                context: CodexToolContext(workspace: configuration.workspace)
            )
        }

        switch call.name {
        case "list_dir":
            return try executeListDir(call)
        case "read_file":
            return try executeReadFile(call)
        case "search_files":
            return try executeSearchFiles(call)
        case "shell_command", "exec_command":
            return try await executeShell(call, progress: progress)
        case "apply_patch":
            return try executeApplyPatch(call)
        case "write_file":
            return try executeWriteFile(call)
        case "view_image":
            return try executeViewImage(call)
        case "update_plan":
            return try executeUpdatePlan(call)
        case "spawn_agent":
            return try await executeSpawnAgent(
                call,
                subagentStatus: subagentStatus,
                subagentEvent: subagentEvent
            )
        case "send_input":
            return try await executeSendInput(call, subagentStatus: subagentStatus, subagentEvent: subagentEvent)
        case "send_message":
            return try await executeSendMessage(call, subagentStatus: subagentStatus)
        case "resume_agent":
            return try await executeResumeAgent(call, subagentStatus: subagentStatus)
        case "followup_task":
            return try await executeFollowupTask(call, subagentStatus: subagentStatus, subagentEvent: subagentEvent)
        case "wait_agent":
            return try await executeWaitAgent(call)
        case "list_agents":
            return try await executeListAgents(call)
        case "close_agent":
            return try await executeCloseAgent(call, subagentStatus: subagentStatus)
        default:
            throw CodexSessionError.unknownTool(call.name)
        }
    }

    func deniedToolResultIfNeeded(for call: CodexToolCall) async -> CodexToolResult? {
        guard case .required(let reason) = approvalRequirement(for: call) else {
            return nil
        }
        let metadata = Self.shellApprovalMetadata(for: call)
        if let metadata, shellApprovalAlreadyGranted(metadata) {
            return nil
        }

        let request = CodexToolApprovalRequest(
            call: call,
            reason: reason,
            summary: approvalSummary(for: call, reason: reason),
            command: metadata?.command,
            workdir: metadata?.workdir,
            sandboxPermissions: metadata?.sandboxPermissions ?? .useDefault,
            justification: metadata?.justification,
            suggestedPrefixRule: metadata?.prefixRule ?? []
        )
        guard let toolApprovalHandler = configuration.toolApprovalHandler else {
            return CodexToolResult(
                output: "Denied \(call.name): approval is required, but the host app did not provide an approval handler.",
                success: false
            )
        }

        switch await toolApprovalHandler(request) {
        case .approve:
            return nil
        case .approveForSession(let prefixRule):
            if let metadata {
                rememberShellPrefixRule(prefixRule, for: metadata)
            }
            return nil
        case .deny(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexToolResult(
                output: trimmed.isEmpty ? "Denied \(call.name)." : "Denied \(call.name): \(trimmed)",
                success: false
            )
        }
    }

    struct ShellApprovalMetadata {
        let command: String
        let workdir: String?
        let sandboxPermissions: CodexToolSandboxPermissions
        let justification: String?
        let prefixRule: [String]
    }

    func shellApprovalAlreadyGranted(_ metadata: ShellApprovalMetadata) -> Bool {
        approvedShellPrefixRules.contains { rule in
            Self.command(metadata.command, hasPrefixRule: rule)
        }
    }

    func rememberShellPrefixRule(_ prefixRule: [String], for metadata: ShellApprovalMetadata) {
        let normalized = Self.normalizedPrefixRule(prefixRule)
        guard metadata.sandboxPermissions == .requireEscalated,
              !normalized.isEmpty,
              Self.command(metadata.command, hasPrefixRule: normalized),
              !approvedShellPrefixRules.contains(normalized) else {
            return
        }
        approvedShellPrefixRules.append(normalized)
    }

    static func shellApprovalMetadata(for call: CodexToolCall) -> ShellApprovalMetadata? {
        guard call.name == "shell_command" || call.name == "exec_command",
              let arguments = try? decodeArguments(call.arguments) else {
            return nil
        }
        let command = (arguments["command"] as? String ?? arguments["cmd"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return nil
        }
        let workdir = trimmedNonEmpty(arguments["workdir"] as? String)
        let sandboxPermissions = (arguments["sandbox_permissions"] as? String)
            .flatMap(CodexToolSandboxPermissions.init(rawValue:)) ?? .useDefault
        let prefixRule = sandboxPermissions == .requireEscalated
            ? normalizedPrefixRule(arguments["prefix_rule"])
            : []
        return ShellApprovalMetadata(
            command: command,
            workdir: workdir,
            sandboxPermissions: sandboxPermissions,
            justification: trimmedNonEmpty(arguments["justification"] as? String),
            prefixRule: prefixRule
        )
    }

    static func normalizedPrefixRule(_ rawValue: Any?) -> [String] {
        guard let values = rawValue as? [Any] else {
            return []
        }
        return normalizedPrefixRule(values.compactMap { $0 as? String })
    }

    static func normalizedPrefixRule(_ values: [String]) -> [String] {
        values.compactMap { trimmedNonEmpty($0) }
    }

    static func command(_ command: String, hasPrefixRule prefixRule: [String]) -> Bool {
        let rule = normalizedPrefixRule(prefixRule)
        guard !rule.isEmpty,
              let words = shellWords(from: command),
              words.count >= rule.count else {
            return false
        }
        return Array(words.prefix(rule.count)) == rule
    }

    static func shellWords(from command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasCurrent = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                hasCurrent = true
                continue
            }

            if character == "\\" && quote != "'" {
                escaping = true
                hasCurrent = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                    hasCurrent = true
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
            } else if isShellWhitespace(character) {
                if hasCurrent {
                    words.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(character)
                hasCurrent = true
            }
        }

        guard quote == nil, !escaping else {
            return nil
        }
        if hasCurrent {
            words.append(current)
        }
        return words
    }

    static func isShellWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    func approvalRequirement(for call: CodexToolCall) -> CodexToolApprovalRequirement {
        if let tool = toolsByName[call.name] {
            return tool.approvalRequirement(for: call)
        }

        switch call.name {
        case "apply_patch":
            return .required(reason: "Apply file edits in the workspace.")
        case "write_file":
            return .required(reason: "Write a file in the workspace.")
        case "shell_command", "exec_command":
            return .required(reason: "Run a shell command in the workspace.")
        default:
            return .none
        }
    }

    func approvalSummary(for call: CodexToolCall, reason: String) -> String {
        let arguments = (try? Self.decodeArguments(call.arguments)) ?? [:]
        switch call.name {
        case "apply_patch":
            return "Apply patch"
        case "write_file":
            let path = arguments["path"] as? String ?? arguments["file_path"] as? String
            return path.map { "Write \($0)" } ?? reason
        case "shell_command", "exec_command":
            let command = arguments["command"] as? String ?? arguments["cmd"] as? String
            return command.map { "Run \($0)" } ?? reason
        default:
            return reason
        }
    }
}
