//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func forkedSnapshot(forkTurns: String?) throws -> CodexSessionSnapshot {
        let normalized = forkTurns?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let forkedHistory: [[String: Any]]
        switch normalized {
        case nil, "", "all":
            forkedHistory = history
        case "none":
            forkedHistory = []
        default:
            if let normalized, let turnCount = Int(normalized), turnCount > 0 {
                let userMessageIndices = history.indices.filter { index in
                    history[index]["type"] as? String == "message"
                        && history[index]["role"] as? String == "user"
                }
                if let startIndex = userMessageIndices.dropLast(max(turnCount - 1, 0)).last {
                    forkedHistory = Array(history[startIndex...])
                } else {
                    forkedHistory = history
                }
            } else {
                forkedHistory = history
            }
        }

        let data = try JSONSerialization.data(withJSONObject: forkedHistory, options: [.sortedKeys])
        return CodexSessionSnapshot(historyJSON: data)
    }

    func startSubagentTurn(
        id: String,
        message: String,
        options: CodexTurnOptions?,
        subagentStatus: CodexSubagentStatusHandler?,
        subagentEvent: CodexSubagentEventHandler?
    ) async {
        guard var record = subagents[id], !record.status.isClosed else {
            return
        }
        let queuedMessages = record.queuedMessages
        record.queuedMessages.removeAll()
        record.status = .running
        record.finalAnswer = nil
        record.errorMessage = nil

        let child = record.session
        let prompt = Self.subagentPrompt(
            path: record.path,
            parentPath: agentPath,
            queuedMessages: queuedMessages,
            message: message
        )
        let agentStatus = Self.subagentStatus(record)
        let task = Task.detached { [child, options] in
            do {
                let output = try await Self.collectFinalText(
                    from: child.submit(userText: prompt, options: options),
                    agent: agentStatus,
                    subagentStatus: { status in
                        await self.emitSubagentStatus(status, to: subagentStatus)
                    },
                    subagentEvent: { event in
                        await self.emitSubagentEvent(event, to: subagentEvent)
                    }
                )
                await self.finishSubagentTurn(
                    id: id,
                    finalAnswer: output,
                    errorMessage: nil,
                    subagentStatus: subagentStatus,
                    subagentEvent: subagentEvent
                )
            } catch is CancellationError {
                await self.finishSubagentTurn(
                    id: id,
                    finalAnswer: nil,
                    errorMessage: "cancelled",
                    subagentStatus: subagentStatus,
                    subagentEvent: subagentEvent
                )
            } catch {
                await self.finishSubagentTurn(
                    id: id,
                    finalAnswer: nil,
                    errorMessage: error.localizedDescription,
                    subagentStatus: subagentStatus,
                    subagentEvent: subagentEvent
                )
            }
        }
        record.task = task
        subagents[id] = record
        await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
    }

    func finishSubagentTurn(
        id: String,
        finalAnswer: String?,
        errorMessage: String?,
        subagentStatus: CodexSubagentStatusHandler?,
        subagentEvent: CodexSubagentEventHandler?
    ) async {
        guard var record = subagents[id], record.status == .running else {
            return
        }
        record.task = nil
        if let errorMessage {
            record.status = .failed
            record.errorMessage = errorMessage
        } else {
            record.status = .completed
            record.finalAnswer = finalAnswer ?? ""
        }

        if !record.status.isClosed, !record.queuedFollowups.isEmpty {
            let next = record.queuedFollowups.removeFirst()
            let options = record.turnOptions
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
            await startSubagentTurn(
                id: id,
                message: next,
                options: options,
                subagentStatus: subagentStatus,
                subagentEvent: subagentEvent
            )
            return
        }

        subagents[id] = record
        await emitSubagentStatus(Self.subagentStatus(record), to: subagentStatus)
    }

    func subagentID(for rawTarget: String) -> String? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return nil
        }
        if subagents[target] != nil {
            return target
        }
        if let exact = subagents.values.first(where: { $0.path == target || $0.taskName == target }) {
            return exact.id
        }
        let canonical = target.hasPrefix("/") ? target : Self.subagentPath(parent: agentPath, taskName: target)
        return subagents.values.first(where: { $0.path == canonical })?.id
    }

    func routedSubagentOwner(for rawTarget: String) async -> CodexSession? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              let owner = await subagentRegistry.owner(for: target, relativeTo: agentPath),
              owner !== self else {
            return nil
        }
        return owner
    }

    func subagentRole(named name: String) -> CodexSubagentRole? {
        configuration.subagentOptions.roles.first { $0.name == name }
    }

    func subagentConfiguration(role: CodexSubagentRole) -> CodexSessionConfiguration {
        guard let roleInstructions = Self.subagentRoleInstructions(role) else {
            return configuration
        }
        let additionalDeveloperInstructions = [
            configuration.additionalDeveloperInstructions,
            roleInstructions,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return CodexSessionConfiguration(
            provider: configuration.provider,
            model: configuration.model,
            authStore: configuration.authStore,
            apiKeyStore: configuration.apiKeyStore,
            chatGPTAuthenticator: configuration.chatGPTAuthenticator,
            workspace: configuration.workspace,
            baseInstructionsOverride: configuration.baseInstructionsOverride,
            additionalDeveloperInstructions: additionalDeveloperInstructions.isEmpty ? nil : additionalDeveloperInstructions,
            contextualUserInstructions: configuration.contextualUserInstructions,
            tools: configuration.tools,
            subagentOptions: configuration.subagentOptions,
            webSearch: configuration.webSearch,
            compactionOptions: configuration.compactionOptions,
            urlSession: configuration.urlSession,
            toolApprovalHandler: configuration.toolApprovalHandler
        )
    }

    static func subagentRoleInstructions(_ role: CodexSubagentRole) -> String? {
        if role.name == CodexSubagentRole.default.name, role.additionalInstructions == nil {
            return nil
        }
        var parts: [String] = []
        if role.name != CodexSubagentRole.default.name {
            parts.append("You are a `\(role.name)` subagent.")
        }
        if !role.description.isEmpty {
            parts.append(role.description)
        }
        if let additionalInstructions = role.additionalInstructions {
            parts.append(additionalInstructions)
        }
        let text = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func subagentNickname(role: CodexSubagentRole, sequence: Int) -> String? {
        guard !role.nicknameCandidates.isEmpty else {
            return nil
        }
        let index = max(0, sequence - 1) % role.nicknameCandidates.count
        return role.nicknameCandidates[index]
    }

    func waitTimeoutMilliseconds(from arguments: [String: Any]) -> Int {
        let options = configuration.subagentOptions
        let requested = Self.intValue(arguments["timeout_ms"]) ?? options.defaultWaitTimeoutMilliseconds
        return min(max(requested, options.minWaitTimeoutMilliseconds), options.maxWaitTimeoutMilliseconds)
    }

    static func waitForSubagentTask(
        _ task: Task<Void, Never>,
        timeoutMilliseconds: Int
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = SubagentWaitRace(continuation)
            let waiter = Task {
                await task.value
                race.finish(true)
            }
            let sleeper = Task {
                let timeout = UInt64(max(timeoutMilliseconds, 1)) * 1_000_000
                try? await Task.sleep(nanoseconds: timeout)
                race.finish(false)
            }
            race.setTasks(waiter: waiter, sleeper: sleeper)
        }
    }

    static func collectFinalText(
        from stream: AsyncThrowingStream<CodexStreamEvent, Error>,
        agent: CodexSubagentStatus? = nil,
        subagentStatus: CodexSubagentStatusHandler? = nil,
        subagentEvent: CodexSubagentEventHandler? = nil
    ) async throws -> String {
        var outputTextByItemID: [String: String] = [:]
        var order: [String] = []
        var fallbackText = ""

        for try await event in stream {
            switch event {
            case .subagentStatus(let status):
                if let subagentStatus {
                    await subagentStatus(status)
                }
            case .subagentEvent(let event):
                if let subagentEvent {
                    await subagentEvent(event)
                }
            default:
                if let agent, let subagentEvent {
                    await subagentEvent(CodexSubagentEvent(agent: agent, event: event))
                }
            }

            switch event {
            case .outputTextDelta(let itemID, let delta):
                guard !delta.isEmpty else {
                    continue
                }
                if let itemID {
                    if outputTextByItemID[itemID] == nil {
                        order.append(itemID)
                    }
                    outputTextByItemID[itemID, default: ""] += delta
                } else {
                    fallbackText += delta
                }
            case .outputItemCompleted(let item):
                guard item.kind == .assistantMessage, let text = item.text, !text.isEmpty else {
                    continue
                }
                if outputTextByItemID[item.id] == nil {
                    order.append(item.id)
                    outputTextByItemID[item.id] = text
                }
            default:
                break
            }
        }

        let joined = order.compactMap { outputTextByItemID[$0] }.joined(separator: "\n")
        let output = joined.isEmpty ? fallbackText : joined
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subagentPrompt(
        path: String,
        parentPath: String,
        queuedMessages: [String],
        message: String
    ) -> String {
        let queued = queuedMessages.isEmpty
            ? ""
            : "\n\nQueued messages from \(parentPath):\n" + queuedMessages.map { "- \($0)" }.joined(separator: "\n")
        return [
            "You are \(path), a child agent spawned by \(parentPath).",
            queued,
            "Task:\n\(message)",
            "When finished, provide the result for \(parentPath).",
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func subagentInputText(from arguments: [String: Any]) -> String {
        if let message = arguments["message"] as? String, !message.isEmpty {
            return message
        }
        guard let items = arguments["items"] as? [[String: Any]] else {
            return ""
        }
        return items.compactMap { item in
            switch item["type"] as? String {
            case "text", "input_text":
                return item["text"] as? String
            case "message":
                if let content = item["content"] as? String {
                    return content
                }
                if let content = item["content"] as? [[String: Any]] {
                    return content.compactMap { part in
                        switch part["type"] as? String {
                        case "text", "input_text":
                            return part["text"] as? String
                        default:
                            return nil
                        }
                    }.joined(separator: "\n")
                }
                return nil
            default:
                return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
}
