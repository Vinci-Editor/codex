//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

public actor CodexSession {
    static let viewImageMaxBytes = 25 * 1024 * 1024
    static let viewImageHighMaxPixelDimension = 2_048
    static let compactionSummaryPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """
    static let compactionSummaryPrefix = """
    Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:
    """
    static let compactUserMessageMaxApproxTokens = 20_000

    let configuration: CodexSessionConfiguration
    let conversationID = UUID().uuidString
    let agentPath: String
    var history: [[String: Any]] = []
    let toolsByName: [String: any CodexTool]
    let subagentRegistry: CodexSubagentRegistry
    var subagents: [String: SubagentRecord] = [:]
    var subagentSequence = 0
    var subagentEventContinuations: [UUID: AsyncStream<CodexStreamEvent>.Continuation] = [:]
    var activeTurnOptions: CodexTurnOptions?
    var approvedShellPrefixRules: [[String]] = []

    public init(configuration: CodexSessionConfiguration) {
        self.configuration = configuration
        self.agentPath = "/root"
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
        self.subagentRegistry = CodexSubagentRegistry()
    }

    public init(configuration: CodexSessionConfiguration, snapshot: CodexSessionSnapshot?) {
        self.configuration = configuration
        self.agentPath = "/root"
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
        self.subagentRegistry = CodexSubagentRegistry()
        if let snapshot,
           let object = try? JSONSerialization.jsonObject(with: snapshot.historyJSON) as? [[String: Any]] {
            self.history = object
        }
    }

    init(
        configuration: CodexSessionConfiguration,
        snapshot: CodexSessionSnapshot?,
        agentPath: String,
        subagentRegistry: CodexSubagentRegistry
    ) {
        self.configuration = configuration
        self.agentPath = agentPath
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
        self.subagentRegistry = subagentRegistry
        if let snapshot,
           let object = try? JSONSerialization.jsonObject(with: snapshot.historyJSON) as? [[String: Any]] {
            self.history = object
        }
    }

    public func clearHistory() {
        history.removeAll()
    }

    public func snapshot() throws -> CodexSessionSnapshot {
        let data = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
        return CodexSessionSnapshot(historyJSON: data)
    }

    public nonisolated func subagentEvents() -> AsyncStream<CodexStreamEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addSubagentEventContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeSubagentEventContinuation(id: id)
                }
            }
        }
    }

    public func cancelSubagents() async {
        for id in Array(subagents.keys) {
            guard var record = subagents[id] else {
                continue
            }
            await record.session.cancelSubagents()
            record.task?.cancel()
            record.task = nil
            if record.status == .running {
                record.status = .failed
                record.errorMessage = "cancelled"
            }
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: nil)
        }
    }

    func closeSubagents() async {
        for id in Array(subagents.keys) {
            guard var record = subagents[id] else {
                continue
            }
            await record.session.closeSubagents()
            let previousStatus = record.status
            record.task?.cancel()
            record.task = nil
            record.statusBeforeClose = previousStatus
            record.status = .closed
            subagents[id] = record
            await emitSubagentStatus(Self.subagentStatus(record), to: nil)
        }
    }

    func addSubagentEventContinuation(
        id: UUID,
        continuation: AsyncStream<CodexStreamEvent>.Continuation
    ) async {
        subagentEventContinuations[id] = continuation
        for status in await subagentRegistry.statusSnapshot() {
            continuation.yield(.subagentStatus(status))
        }
    }

    func removeSubagentEventContinuation(id: UUID) {
        subagentEventContinuations[id] = nil
    }

    func yieldSubagentStreamEvent(_ event: CodexStreamEvent) {
        for continuation in subagentEventContinuations.values {
            continuation.yield(event)
        }
    }

    func emitSubagentStatus(
        _ status: CodexSubagentStatus,
        to handler: CodexSubagentStatusHandler?
    ) async {
        let owner = subagents[status.agentID]?.path == status.path ? self : nil
        await subagentRegistry.update(status, owner: owner)
        if let handler {
            await handler(status)
        }
        yieldSubagentStreamEvent(.subagentStatus(status))
    }

    func emitSubagentEvent(
        _ event: CodexSubagentEvent,
        to handler: CodexSubagentEventHandler?
    ) async {
        if let handler {
            await handler(event)
        }
        yieldSubagentStreamEvent(.subagentEvent(event))
    }

    public func compactHistory(options: CodexTurnOptions? = nil) async throws -> CodexCompactionResult {
        guard !history.isEmpty else {
            throw CodexSessionError.compactionUnavailable("No session history to compact.")
        }

        return try await performCompaction(options: options)
    }

    public func executeToolCall(_ call: CodexToolCall) async throws -> Data {
        let result = try await executeTool(call)
        appendToolOutput(call: call, result: result)
        return try JSONSerialization.data(
            withJSONObject: CodexMobileCoreBridge.toolOutput(
                callID: call.callID,
                output: result.responseOutput?.jsonValue ?? result.output,
                success: result.success,
                custom: call.kind == .custom,
                name: call.name
            ),
            options: [.sortedKeys]
        )
    }

    public func submit(userText: String) -> AsyncThrowingStream<CodexStreamEvent, Error> {
        submit(userText: userText, options: nil)
    }

    public func submit(userText: String, options: CodexTurnOptions?) -> AsyncThrowingStream<CodexStreamEvent, Error> {
        submit(inputs: [.text(userText)], options: options)
    }

    public func submit(inputs: [CodexInput], options: CodexTurnOptions? = nil) -> AsyncThrowingStream<CodexStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(inputs: inputs, options: options, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
