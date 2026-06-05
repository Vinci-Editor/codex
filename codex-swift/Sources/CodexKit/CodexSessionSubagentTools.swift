//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func executeSpawnAgent(
        _ call: CodexToolCall,
        subagentStatus: CodexSubagentStatusHandler?,
        subagentEvent: CodexSubagentEventHandler?
    ) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let taskName = (arguments["task_name"] as? String ?? arguments["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (arguments["message"] as? String ?? arguments["task"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSubagentTaskName(taskName) else {
            return CodexToolResult(
                output: "Invalid task_name. Use lowercase letters, digits, and underscores.",
                success: false
            )
        }
        guard !message.isEmpty else {
            return CodexToolResult(output: "Missing message.", success: false)
        }
        let roleName = Self.trimmedNonEmpty(arguments["agent_type"] as? String) ?? CodexSubagentRole.default.name
        guard CodexSubagentOptions.isValidRoleName(roleName) else {
            return CodexToolResult(
                output: "Invalid agent_type. Use letters, digits, underscores, or hyphens.",
                success: false
            )
        }
        guard let role = subagentRole(named: roleName) else {
            return CodexToolResult(
                output: "Unknown agent_type `\(roleName)`. Available agent types: \(Self.availableValuesDescription(configuration.subagentOptions.roles.map(\.name))).",
                success: false
            )
        }
        if let validationError = Self.subagentSpawnArgumentsValidationError(arguments: arguments, parentOptions: activeTurnOptions, role: role) {
            return CodexToolResult(output: validationError, success: false)
        }

        let childPath = Self.subagentPath(parent: agentPath, taskName: taskName)
        if let maxDepth = configuration.subagentOptions.maxDepth,
           Self.subagentDepth(path: childPath) > maxDepth {
            return CodexToolResult(
                output: "Subagent depth limit reached (\(maxDepth)). Solve the task yourself.",
                success: false
            )
        }
        guard !subagents.values.contains(where: { $0.path == childPath }) else {
            return CodexToolResult(output: "\(childPath): agent already exists.", success: false)
        }
        let snapshot = try forkedSnapshot(forkTurns: arguments["fork_turns"] as? String)
        guard let id = await subagentRegistry.reserveAgent(maxOpenAgents: configuration.subagentOptions.maxOpenAgents) else {
            return CodexToolResult(
                output: "Subagent limit reached (\(configuration.subagentOptions.maxOpenAgents) open agents).",
                success: false
            )
        }

        subagentSequence += 1
        let roleNameForStatus = role.name == CodexSubagentRole.default.name ? nil : role.name
        let nickname = Self.subagentNickname(role: role, sequence: subagentSequence)
        let child = CodexSession(
            configuration: subagentConfiguration(role: role),
            snapshot: snapshot,
            agentPath: childPath,
            subagentRegistry: subagentRegistry
        )
        let options = Self.subagentTurnOptions(arguments: arguments, parentOptions: activeTurnOptions, role: role)

        subagents[id] = SubagentRecord(
            id: id,
            taskName: taskName,
            path: childPath,
            agentRole: roleNameForStatus,
            agentNickname: nickname,
            session: child,
            status: .running,
            turnOptions: options,
            createdOrder: subagentSequence
        )
        await startSubagentTurn(
            id: id,
            message: message,
            options: options,
            subagentStatus: subagentStatus,
            subagentEvent: subagentEvent
        )

        if let latest = subagents[id] {
            return CodexToolResult(output: try Self.jsonString(Self.subagentStatusPayload(latest)))
        }
        return CodexToolResult(output: try Self.jsonString([
            "agent_id": id,
            "task_name": childPath,
            "status": SubagentStatus.running.rawValue,
        ]))
    }

    func executeSendMessage(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return CodexToolResult(output: "Missing message.", success: false)
        }
        if subagentID(for: target) == nil, let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeSendMessage(call, subagentStatus: subagentStatus)
        }
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        guard !record.status.isClosed else {
            return CodexToolResult(output: "\(record.path): agent is closed.", success: false)
        }

        record.queuedMessages.append(message)
        subagents[id] = record
        await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "status": "queued",
        ]))
    }

    func executeSendInput(
        _ call: CodexToolCall,
        subagentStatus: CodexSubagentStatusHandler?,
        subagentEvent: CodexSubagentEventHandler?
    ) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        let message = Self.subagentInputText(from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let interrupt = Self.boolValue(arguments["interrupt"])
        guard !message.isEmpty else {
            return CodexToolResult(output: "Missing message or text input items.", success: false)
        }
        if subagentID(for: target) == nil, let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeSendInput(
                call,
                subagentStatus: subagentStatus,
                subagentEvent: subagentEvent
            )
        }
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        guard !record.status.isClosed else {
            return CodexToolResult(output: "\(record.path): agent is closed; call resume_agent before send_input.", success: false)
        }

        if record.status == .running, !interrupt {
            record.queuedMessages.append(message)
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
            return CodexToolResult(output: try Self.jsonString([
                "target": record.path,
                "status": "queued",
                "submission_id": UUID().uuidString,
            ]))
        }

        if record.status == .running, interrupt {
            record.queuedFollowups.insert(message, at: 0)
            record.task?.cancel()
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
            return CodexToolResult(output: try Self.jsonString([
                "target": record.path,
                "status": "interrupt_queued",
                "submission_id": UUID().uuidString,
            ]))
        }
        record.status = .running
        record.finalAnswer = nil
        record.errorMessage = nil
        subagents[id] = record
        await startSubagentTurn(
            id: id,
            message: message,
            options: record.turnOptions,
            subagentStatus: subagentStatus,
            subagentEvent: subagentEvent
        )
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "status": "running",
            "submission_id": UUID().uuidString,
        ]))
    }

    func executeResumeAgent(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["id"] as? String ?? arguments["target"] as? String ?? ""
        if subagentID(for: target) == nil, let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeResumeAgent(call, subagentStatus: subagentStatus)
        }
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        if record.status.isClosed {
            guard await subagentRegistry.reserveAgent(id: id, maxOpenAgents: configuration.subagentOptions.maxOpenAgents) else {
                return CodexToolResult(
                    output: "Subagent limit reached (\(configuration.subagentOptions.maxOpenAgents) open agents).",
                    success: false
                )
            }
            record.status = record.statusBeforeClose ?? .completed
            record.statusBeforeClose = nil
            subagents[id] = record
        }
        guard let latest = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        await emitSubagentStatus(Self.subagentStatus(latest), to: subagentStatus)
        return CodexToolResult(output: try Self.jsonString(Self.subagentStatusPayload(latest)))
    }

    func executeFollowupTask(
        _ call: CodexToolCall,
        subagentStatus: CodexSubagentStatusHandler?,
        subagentEvent: CodexSubagentEventHandler?
    ) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return CodexToolResult(output: "Missing message.", success: false)
        }
        if subagentID(for: target) == nil, let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeFollowupTask(
                call,
                subagentStatus: subagentStatus,
                subagentEvent: subagentEvent
            )
        }
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        guard !record.status.isClosed else {
            return CodexToolResult(output: "\(record.path): agent is closed.", success: false)
        }

        if record.status == .running {
            record.queuedFollowups.append(message)
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
            return CodexToolResult(output: try Self.jsonString([
                "target": record.path,
                "status": "queued",
            ]))
        }

        subagents[id] = record
        await startSubagentTurn(
            id: id,
            message: message,
            options: record.turnOptions,
            subagentStatus: subagentStatus,
            subagentEvent: subagentEvent
        )
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "status": "running",
        ]))
    }

    func executeWaitAgent(_ call: CodexToolCall) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String
        let timeout = waitTimeoutMilliseconds(from: arguments)
        if let target, !target.isEmpty,
           subagentID(for: target) == nil,
           let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeWaitAgent(call)
        }

        let id: String?
        if let target, !target.isEmpty {
            id = subagentID(for: target)
        } else {
            id = subagents.values
                .sorted { $0.createdOrder < $1.createdOrder }
                .first(where: { $0.status == .running || $0.status.isFinal })?
                .id
        }
        guard let id, let record = subagents[id] else {
            return CodexToolResult(output: "No matching agent.", success: false)
        }

        if record.status == .running, let task = record.task {
            let completed = await Self.waitForSubagentTask(task, timeoutMilliseconds: timeout)
            if !completed, let latest = subagents[id] {
                return CodexToolResult(output: try Self.jsonString([
                    "target": latest.path,
                    "status": "timeout",
                    "timeout_ms": timeout,
                ]))
            }
        }

        guard let latest = subagents[id] else {
            return CodexToolResult(output: "\(record.path): agent not found.", success: false)
        }
        return CodexToolResult(output: try Self.jsonString(Self.subagentStatusPayload(latest)))
    }

    func executeListAgents(_ call: CodexToolCall) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let prefix = subagentPathPrefix(arguments["path_prefix"] as? String)
        let agents = await subagentRegistry.statusSnapshot()
            .filter { status in
                guard let prefix else {
                    return true
                }
                return status.path == prefix || status.path.hasPrefix("\(prefix)/")
            }
            .map(Self.subagentStatusPayload)
        return CodexToolResult(output: try Self.jsonString(["agents": agents]))
    }

    func executeCloseAgent(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        if subagentID(for: target) == nil, let owner = await routedSubagentOwner(for: target) {
            return try await owner.executeCloseAgent(call, subagentStatus: subagentStatus)
        }
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        let previousStatus = record.status
        await record.session.closeSubagents()
        record.task?.cancel()
        record.task = nil
        record.statusBeforeClose = previousStatus
        record.status = .closed
        subagents[id] = record
        await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "previous_status": previousStatus.rawValue,
            "status": record.status.rawValue,
        ]))
    }
}
