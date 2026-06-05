//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func buildInstructions() -> String {
        [
            configuration.baseInstructionsOverride,
            multiAgentInstructions(),
            workspaceInstructions(),
            configuration.additionalDeveloperInstructions,
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func requestInputHistory(
        from items: [[String: Any]]? = nil,
        includeDynamicContext: Bool = true
    ) async -> [[String: Any]] {
        let input = Self.requestInputHistory(
            contextualUserInstructions: configuration.contextualUserInstructions,
            history: items ?? history
        )
        guard includeDynamicContext, let subagentContextMessage = await subagentEnvironmentContextMessage() else {
            return input
        }
        return [subagentContextMessage] + input
    }

    static func requestInputHistory(
        contextualUserInstructions: String?,
        history: [[String: Any]]
    ) -> [[String: Any]] {
        let trimmedInstructions = contextualUserInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedInstructions, !trimmedInstructions.isEmpty else {
            return history
        }
        return [
            message(role: "user", textType: "input_text", text: trimmedInstructions)
        ] + history
    }

    func subagentEnvironmentContextMessage() async -> [String: Any]? {
        let statuses = await subagentRegistry.statusSnapshot()
        guard let context = Self.subagentEnvironmentContext(statuses: statuses) else {
            return nil
        }
        return Self.message(role: "user", textType: "input_text", text: context)
    }

    static func subagentEnvironmentContext(statuses: [CodexSubagentStatus]) -> String? {
        let openStatuses = statuses.filter { $0.status != SubagentStatus.closed.rawValue }
        guard !openStatuses.isEmpty else {
            return nil
        }

        var lines = openStatuses
            .prefix(maxSubagentEnvironmentContextAgents)
            .map(subagentEnvironmentContextLine)
        let hiddenCount = openStatuses.count - lines.count
        if hiddenCount > 0 {
            lines.append("- \(hiddenCount) more subagent\(hiddenCount == 1 ? "" : "s") available via list_agents")
        }

        let body = lines
            .map { "    \($0)" }
            .joined(separator: "\n")
        return """
        <environment_context>
          <subagents>
        \(body)
          </subagents>
        </environment_context>
        """
    }

    static func subagentEnvironmentContextLine(_ status: CodexSubagentStatus) -> String {
        var parts = [
            "- \(escapeEnvironmentContext(status.agentID)): \(escapeEnvironmentContext(subagentContextDisplayName(status)))",
            "path=\(escapeEnvironmentContext(status.path))",
            "status=\(escapeEnvironmentContext(status.status))",
        ]
        if let role = status.agentRole, !role.isEmpty {
            parts.append("agent_type=\(escapeEnvironmentContext(role))")
        }
        if let nickname = status.agentNickname, !nickname.isEmpty {
            parts.append("nickname=\(escapeEnvironmentContext(nickname))")
        }
        if status.queuedMessages > 0 {
            parts.append("queued_messages=\(status.queuedMessages)")
        }
        if status.queuedFollowups > 0 {
            parts.append("queued_followups=\(status.queuedFollowups)")
        }
        if !status.modelSettings.isEmpty {
            let settings = status.modelSettings
                .sorted { $0.key < $1.key }
                .map { "\(escapeEnvironmentContext($0.key))=\(escapeEnvironmentContext($0.value))" }
                .joined(separator: ",")
            parts.append("model_settings={\(settings)}")
        }
        if let finalAnswer = status.finalAnswer, !finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("final_answer_preview=\"\(subagentEnvironmentContextPreview(finalAnswer))\"")
        }
        if let error = status.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("error=\"\(subagentEnvironmentContextPreview(error))\"")
        }
        return parts.joined(separator: " ")
    }

    static func subagentContextDisplayName(_ status: CodexSubagentStatus) -> String {
        if let nickname = status.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname
        }
        let candidate = status.taskName.isEmpty ? status.path : status.taskName
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? status.agentID
    }

    static func subagentEnvironmentContextPreview(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let prefix = String(normalized.prefix(maxSubagentEnvironmentContextPreviewCharacters))
        let suffix = normalized.count > maxSubagentEnvironmentContextPreviewCharacters ? "..." : ""
        return escapeEnvironmentContext(prefix + suffix)
    }

    static func escapeEnvironmentContext(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func buildToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
        let supportsImages = Self.modelSupportsImages(inputModalities: options?.inputModalities)
        let builtinTools = CodexMobileCoreBridge.builtinTools().filter { tool in
            guard tool["name"] as? String == "view_image" else {
                return true
            }
            return supportsImages
        }
        return hostedToolDefinitions(options: options)
            + builtinTools
            + subagentToolDefinitions(options: options)
            + configuration.tools.map { $0.responsesToolDefinition() }
    }

    func hostedToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
        guard configuration.provider.id == "openai",
              let webSearch = options?.webSearch ?? configuration.webSearch,
              webSearch.isEnabled else {
            return []
        }
        return [webSearch.responsesToolDefinition]
    }

    static func modelSupportsImages(inputModalities: [String]?) -> Bool {
        guard let inputModalities, !inputModalities.isEmpty else {
            return true
        }
        return inputModalities.contains { $0.lowercased() == "image" }
    }


    func workspaceInstructions() -> String? {
        guard let workspace = configuration.workspace else {
            return "No workspace is selected. If the user asks about files, say that a workspace must be selected first."
        }
        return """
        Current workspace: \(workspace.rootURL.path)
        Use list_dir, read_file, and search_files to inspect files before answering questions about the workspace. Prefer apply_patch for focused edits and write_file for complete-file writes. Use shell_command or exec_command only when a real shell is needed. Do not claim you have read files unless a tool result has provided their contents.
        """
    }

    func multiAgentInstructions() -> String? {
        guard configuration.subagentOptions.isEnabled else {
            return nil
        }
        if agentPath == "/root" {
            return """
            You are `/root`, the primary agent in a team of agents collaborating to fulfill the user's goals.

            You can use `spawn_agent` to create a child agent, `send_input` to send reusable agent input, `resume_agent` to reopen a closed agent, `followup_task` to give an existing child agent a new task and trigger a turn, `send_message` to pass a message to an existing child without triggering a turn, `wait_agent` to wait for child output, `list_agents` to inspect live child agents, and `close_agent` to close agents that are no longer needed. Use subagents only when delegation or parallel work materially helps the user request.
            """
        }
        return """
        You are `\(agentPath)`, a child agent in a team of agents collaborating to complete a task.

        You can use `spawn_agent` to create a child agent, `send_input` to send reusable agent input, `resume_agent` to reopen a closed agent, `followup_task` to give an existing child agent a new task and trigger a turn, `send_message` to pass a message to an existing child without triggering a turn, `wait_agent` to wait for child output, `list_agents` to inspect live child agents, and `close_agent` to close agents that are no longer needed. When you provide a final answer, that content is delivered back to your parent agent.
        """
    }
}
