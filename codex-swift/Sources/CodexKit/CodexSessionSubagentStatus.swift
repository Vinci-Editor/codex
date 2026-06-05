//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    static func subagentStatusPayload(_ record: SubagentRecord) -> [String: Any] {
        subagentStatusPayload(subagentStatus(record))
    }

    static func subagentStatusPayload(_ status: CodexSubagentStatus) -> [String: Any] {
        var payload: [String: Any] = [
            "agent_id": status.agentID,
            "task_name": status.path,
            "status": status.status,
        ]
        if let agentRole = status.agentRole {
            payload["agent_type"] = agentRole
            payload["agent_role"] = agentRole
        }
        if let agentNickname = status.agentNickname {
            payload["nickname"] = agentNickname
            payload["agent_nickname"] = agentNickname
        }
        if !status.modelSettings.isEmpty {
            payload["model_settings"] = status.modelSettings
        }
        if let finalAnswer = status.finalAnswer {
            payload["final_answer"] = finalAnswer
        }
        if let error = status.error {
            payload["error"] = error
        }
        if status.queuedMessages > 0 {
            payload["queued_messages"] = status.queuedMessages
        }
        if status.queuedFollowups > 0 {
            payload["queued_followups"] = status.queuedFollowups
        }
        return payload
    }

    static func subagentStatus(_ record: SubagentRecord) -> CodexSubagentStatus {
        CodexSubagentStatus(
            agentID: record.id,
            taskName: record.taskName,
            path: record.path,
            agentRole: record.agentRole,
            agentNickname: record.agentNickname,
            status: record.status.rawValue,
            finalAnswer: record.status == .completed ? record.finalAnswer ?? "" : nil,
            error: record.status == .failed ? record.errorMessage ?? "Subagent failed." : nil,
            queuedMessages: record.queuedMessages.count,
            queuedFollowups: record.queuedFollowups.count,
            modelSettings: subagentModelSettingsPayload(record.turnOptions)
        )
    }

    static func subagentModelSettingsPayload(_ options: CodexTurnOptions?) -> [String: String] {
        var payload: [String: String] = [:]
        if let model = options?.model, !model.isEmpty {
            payload["model"] = model
        }
        if let reasoningEffort = options?.reasoningEffort, !reasoningEffort.isEmpty {
            payload["reasoning_effort"] = reasoningEffort
        }
        if let reasoningSummary = options?.reasoningSummary {
            payload["reasoning_summary"] = reasoningSummary.rawValue
        }
        if let serviceTier = options?.serviceTier, !serviceTier.isEmpty {
            payload["service_tier"] = serviceTier
        }
        if let verbosity = options?.verbosity {
            payload["verbosity"] = verbosity.rawValue
        }
        return payload
    }

    static func subagentPath(parent: String, taskName: String) -> String {
        parent == "/" ? "/\(taskName)" : "\(parent)/\(taskName)"
    }

    static func subagentDepth(path: String) -> Int {
        let components = path
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty else {
            return 0
        }
        if components.first == "root" {
            return max(0, components.count - 1)
        }
        return components.count
    }

    func subagentPathPrefix(_ rawPrefix: String?) -> String? {
        guard let rawPrefix = rawPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPrefix.isEmpty else {
            return nil
        }

        let prefix = rawPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.isEmpty else {
            return nil
        }

        if rawPrefix.hasPrefix("/") {
            return "/\(prefix)"
        }
        return Self.subagentPath(parent: agentPath, taskName: prefix)
    }

    static func isValidSubagentTaskName(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        return value.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil
    }

    static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
