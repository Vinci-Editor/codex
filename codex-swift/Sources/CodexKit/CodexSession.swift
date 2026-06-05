import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

private let maxSubagentModelOverrideDescriptions = 8
private let maxSubagentEnvironmentContextAgents = 8
private let maxSubagentEnvironmentContextPreviewCharacters = 600
private typealias CodexSubagentStatusHandler = @Sendable (CodexSubagentStatus) async -> Void
private typealias CodexSubagentEventHandler = @Sendable (CodexSubagentEvent) async -> Void

public struct CodexCompactionOptions: Codable, Sendable, Equatable, Hashable {
    public let automaticTriggerApproxTokens: Int?

    public init(automaticTriggerApproxTokens: Int? = nil) {
        self.automaticTriggerApproxTokens = automaticTriggerApproxTokens.map { max($0, 1) }
    }

    public static let disabled = CodexCompactionOptions()

    public static func automatic(triggerApproxTokens: Int = 200_000) -> CodexCompactionOptions {
        CodexCompactionOptions(automaticTriggerApproxTokens: triggerApproxTokens)
    }
}

public struct CodexSessionConfiguration: Sendable {
    public let provider: CodexProvider
    public let model: String
    public let authStore: (any CodexAuthStore)?
    public let apiKeyStore: (any CodexAPIKeyStore)?
    public let chatGPTAuthenticator: CodexDeviceCodeAuthenticator?
    public let workspace: CodexWorkspace?
    public let baseInstructionsOverride: String?
    public let additionalDeveloperInstructions: String?
    public let contextualUserInstructions: String?
    public let tools: [any CodexTool]
    public let subagentOptions: CodexSubagentOptions
    public let webSearch: CodexWebSearchOptions?
    public let compactionOptions: CodexCompactionOptions
    public let urlSession: URLSession
    public let toolApprovalHandler: CodexToolApprovalHandler?

    public init(
        provider: CodexProvider = .openAI,
        model: String = "gpt-5.5",
        authStore: (any CodexAuthStore)? = nil,
        apiKeyStore: (any CodexAPIKeyStore)? = nil,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator? = nil,
        workspace: CodexWorkspace? = nil,
        baseInstructionsOverride: String? = nil,
        additionalDeveloperInstructions: String? = nil,
        contextualUserInstructions: String? = nil,
        tools: [any CodexTool] = [],
        subagentOptions: CodexSubagentOptions = .disabled,
        webSearch: CodexWebSearchOptions? = nil,
        compactionOptions: CodexCompactionOptions = .disabled,
        urlSession: URLSession = .shared,
        toolApprovalHandler: CodexToolApprovalHandler? = nil
    ) {
        self.provider = provider
        self.model = model
        self.authStore = authStore
        self.apiKeyStore = apiKeyStore
        self.chatGPTAuthenticator = chatGPTAuthenticator
        self.workspace = workspace
        self.baseInstructionsOverride = baseInstructionsOverride
        self.additionalDeveloperInstructions = additionalDeveloperInstructions
        self.contextualUserInstructions = contextualUserInstructions
        self.tools = tools
        self.subagentOptions = subagentOptions
        self.webSearch = webSearch
        self.compactionOptions = compactionOptions
        self.urlSession = urlSession
        self.toolApprovalHandler = toolApprovalHandler
    }

    public func withToolApprovalHandler(_ handler: CodexToolApprovalHandler?) -> CodexSessionConfiguration {
        CodexSessionConfiguration(
            provider: provider,
            model: model,
            authStore: authStore,
            apiKeyStore: apiKeyStore,
            chatGPTAuthenticator: chatGPTAuthenticator,
            workspace: workspace,
            baseInstructionsOverride: baseInstructionsOverride,
            additionalDeveloperInstructions: additionalDeveloperInstructions,
            contextualUserInstructions: contextualUserInstructions,
            tools: tools,
            subagentOptions: subagentOptions,
            webSearch: webSearch,
            compactionOptions: compactionOptions,
            urlSession: urlSession,
            toolApprovalHandler: handler
        )
    }

    public func withAdditionalTools(_ additionalTools: [any CodexTool]) -> CodexSessionConfiguration {
        CodexSessionConfiguration(
            provider: provider,
            model: model,
            authStore: authStore,
            apiKeyStore: apiKeyStore,
            chatGPTAuthenticator: chatGPTAuthenticator,
            workspace: workspace,
            baseInstructionsOverride: baseInstructionsOverride,
            additionalDeveloperInstructions: additionalDeveloperInstructions,
            contextualUserInstructions: contextualUserInstructions,
            tools: tools + additionalTools,
            subagentOptions: subagentOptions,
            webSearch: webSearch,
            compactionOptions: compactionOptions,
            urlSession: urlSession,
            toolApprovalHandler: toolApprovalHandler
        )
    }
}

public struct CodexOutputItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case assistantMessage
        case reasoning
        case functionCall
        case customToolCall
        case webSearchCall
        case unknown
    }

    public let id: String
    public let kind: Kind
    public let role: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let text: String?

    public init(
        id: String,
        kind: Kind,
        role: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        text: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.text = text
    }

    public var toolCall: CodexToolCall? {
        guard
            let callID,
            let name,
            kind == .functionCall || kind == .customToolCall
        else {
            return nil
        }
        return CodexToolCall(
            itemID: id,
            callID: callID,
            name: name,
            arguments: arguments ?? "{}",
            kind: kind == .customToolCall ? .custom : .function
        )
    }
}

public struct CodexWebSearchCall: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let status: String?
    public let actionType: String
    public let detail: String

    public init(id: String, status: String? = nil, actionType: String = "other", detail: String = "") {
        self.id = id
        self.status = status
        self.actionType = actionType
        self.detail = detail
    }

    public var isCompleted: Bool {
        status == nil || status == "completed"
    }
}

public enum CodexStreamEvent: Sendable, Equatable {
    case created
    case outputItemStarted(CodexOutputItem)
    case outputItemCompleted(CodexOutputItem)
    case outputTextDelta(itemID: String?, delta: String)
    case reasoningSummaryDelta(itemID: String?, delta: String)
    case toolCallInputDelta(itemID: String?, callID: String?, delta: String)
    case toolOutputDelta(CodexToolCall, String)
    case outputItemAdded(Data)
    case outputItemDone(Data)
    case completed(Data, CodexTokenUsage?)
    case planUpdated(CodexPlanUpdate)
    case webSearch(CodexWebSearchCall)
    case contextCompacted(CodexCompactionResult)
    case subagentStatus(CodexSubagentStatus)
    indirect case subagentEvent(CodexSubagentEvent)
    case toolCall(CodexToolCall)
    case toolResult(CodexToolCall, String, Bool)
    case error(String)
    case raw(Data)
}

public struct CodexSubagentStatus: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let agentID: String
    public let taskName: String
    public let path: String
    public let status: String
    public let finalAnswer: String?
    public let error: String?
    public let queuedMessages: Int
    public let queuedFollowups: Int
    public let modelSettings: [String: String]

    public var id: String { agentID }

    public init(
        agentID: String,
        taskName: String,
        path: String,
        status: String,
        finalAnswer: String? = nil,
        error: String? = nil,
        queuedMessages: Int = 0,
        queuedFollowups: Int = 0,
        modelSettings: [String: String] = [:]
    ) {
        self.agentID = agentID
        self.taskName = taskName
        self.path = path
        self.status = status
        self.finalAnswer = finalAnswer
        self.error = error
        self.queuedMessages = queuedMessages
        self.queuedFollowups = queuedFollowups
        self.modelSettings = modelSettings
    }
}

public struct CodexSubagentEvent: Sendable, Equatable {
    public let agent: CodexSubagentStatus
    public let event: CodexStreamEvent

    public init(agent: CodexSubagentStatus, event: CodexStreamEvent) {
        self.agent = agent
        self.event = event
    }
}

public struct CodexSessionSnapshot: Codable, Sendable, Equatable, Hashable {
    public let historyJSON: Data

    public init(historyJSON: Data) {
        self.historyJSON = historyJSON
    }
}

public struct CodexCompactionResult: Codable, Sendable, Equatable, Hashable {
    public let summary: String
    public let originalItemCount: Int
    public let compactedItemCount: Int

    public init(summary: String, originalItemCount: Int, compactedItemCount: Int) {
        self.summary = summary
        self.originalItemCount = originalItemCount
        self.compactedItemCount = compactedItemCount
    }
}

public actor CodexSession {
    private static let viewImageMaxBytes = 25 * 1024 * 1024
    private static let viewImageHighMaxPixelDimension = 2_048
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
    private static let compactUserMessageMaxApproxTokens = 20_000

    private let configuration: CodexSessionConfiguration
    private let conversationID = UUID().uuidString
    private let agentPath: String
    private var history: [[String: Any]] = []
    private let toolsByName: [String: any CodexTool]
    private var subagents: [String: SubagentRecord] = [:]
    private var subagentSequence = 0
    private var subagentEventContinuations: [UUID: AsyncStream<CodexStreamEvent>.Continuation] = [:]
    private var activeTurnOptions: CodexTurnOptions?
    private var approvedShellPrefixRules: [[String]] = []

    public init(configuration: CodexSessionConfiguration) {
        self.configuration = configuration
        self.agentPath = "/root"
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
    }

    public init(configuration: CodexSessionConfiguration, snapshot: CodexSessionSnapshot?) {
        self.configuration = configuration
        self.agentPath = "/root"
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
        if let snapshot,
           let object = try? JSONSerialization.jsonObject(with: snapshot.historyJSON) as? [[String: Any]] {
            self.history = object
        }
    }

    private init(configuration: CodexSessionConfiguration, snapshot: CodexSessionSnapshot?, agentPath: String) {
        self.configuration = configuration
        self.agentPath = agentPath
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
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

    public func cancelSubagents() {
        for id in Array(subagents.keys) {
            guard var record = subagents[id] else {
                continue
            }
            record.task?.cancel()
            record.task = nil
            if record.status == .running {
                record.status = .failed
                record.errorMessage = "cancelled"
            }
            subagents[id] = record
            yieldSubagentStreamEvent(.subagentStatus(Self.subagentStatus(record)))
        }
    }

    private func addSubagentEventContinuation(
        id: UUID,
        continuation: AsyncStream<CodexStreamEvent>.Continuation
    ) {
        subagentEventContinuations[id] = continuation
        for record in subagents.values.sorted(by: { $0.createdOrder < $1.createdOrder }) {
            continuation.yield(.subagentStatus(Self.subagentStatus(record)))
        }
    }

    private func removeSubagentEventContinuation(id: UUID) {
        subagentEventContinuations[id] = nil
    }

    private func yieldSubagentStreamEvent(_ event: CodexStreamEvent) {
        for continuation in subagentEventContinuations.values {
            continuation.yield(event)
        }
    }

    private func emitSubagentStatus(
        _ status: CodexSubagentStatus,
        to handler: CodexSubagentStatusHandler?
    ) async {
        if let handler {
            await handler(status)
        }
        yieldSubagentStreamEvent(.subagentStatus(status))
    }

    private func emitSubagentEvent(
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

    private func runTurn(
        inputs: [CodexInput],
        options: CodexTurnOptions?,
        continuation: AsyncThrowingStream<CodexStreamEvent, Error>.Continuation
    ) async throws {
        let previousTurnOptions = activeTurnOptions
        activeTurnOptions = options
        defer {
            activeTurnOptions = previousTurnOptions
        }

        if let compactionResult = try await automaticCompactionIfNeeded(options: options) {
            continuation.yield(.contextCompacted(compactionResult))
        }

        history.append([
            "type": "message",
            "role": "user",
            "content": inputs.map(\.responsesContentPart),
        ])

        for _ in 0..<8 {
            let result = try await streamOneRequest(options: options, continuation: continuation)
            for item in result.assistantTextItems where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                history.append([
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": item.text]],
                ])
            }
            guard !result.toolCalls.isEmpty else {
                return
            }
            for call in result.toolCalls {
                let toolResult = try await executeTool(
                    call,
                    progress: { progress in
                        guard let delta = progress.outputDelta, !delta.isEmpty else {
                            return
                        }
                        continuation.yield(.toolOutputDelta(call, delta))
                    },
                    subagentStatus: { status in
                        continuation.yield(.subagentStatus(status))
                    },
                    subagentEvent: { event in
                        continuation.yield(.subagentEvent(event))
                    }
                )
                appendToolOutput(call: call, result: toolResult)
                if let planUpdate = toolResult.planUpdate {
                    continuation.yield(.planUpdated(planUpdate))
                }
                continuation.yield(.toolResult(call, toolResult.output, toolResult.success))
            }
        }

        throw CodexSessionError.toolLoopLimitExceeded
    }

    private func automaticCompactionIfNeeded(options: CodexTurnOptions?) async throws -> CodexCompactionResult? {
        guard let trigger = configuration.compactionOptions.automaticTriggerApproxTokens,
              trigger > 0,
              Self.approximateHistoryTokenCount(history) >= trigger else {
            return nil
        }
        return try await performCompaction(options: options)
    }

    private func performCompaction(options: CodexTurnOptions?) async throws -> CodexCompactionResult {
        let originalHistory = history
        let summary = try await requestCompactionSummary(from: originalHistory, options: options)
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSummary = normalizedSummary.isEmpty ? "(no summary available)" : normalizedSummary
        let compactedHistory = Self.compactedHistory(summary: finalSummary, from: originalHistory)
        history = compactedHistory
        return CodexCompactionResult(
            summary: finalSummary,
            originalItemCount: originalHistory.count,
            compactedItemCount: compactedHistory.count
        )
    }

    private func requestCompactionSummary(
        from baseHistory: [[String: Any]],
        options: CodexTurnOptions?
    ) async throws -> String {
        let compactionInput = requestInputHistory(from: baseHistory, includeDynamicContext: false) + [
            Self.message(role: "user", textType: "input_text", text: Self.compactionSummaryPrompt)
        ]
        let reasoning = Self.reasoningParameter(options: options)
        var input: [String: Any] = [
            "model": options?.model ?? configuration.model,
            "instructions": buildInstructions(),
            "input": compactionInput,
            "tools": [],
            "stream": true,
            "store": false,
            "reasoning": reasoning,
            "toolChoice": "none",
            "parallelToolCalls": false,
            "include": Self.includeParameter(reasoning: reasoning),
            "promptCacheKey": "\(conversationID)-compact",
            "metadata": [
                "codex_client": "CodexKit",
                "request_kind": "compaction",
            ],
        ]
        if let serviceTier = options?.serviceTier {
            input["serviceTier"] = serviceTier
        }
        if let text = Self.textParameter(options: options) {
            input["text"] = text
        }
        let body = try CodexMobileCoreBridge.buildResponsesRequest(input)
        input.removeAll(keepingCapacity: false)

        var request = URLRequest(url: configuration.provider.responsesURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in configuration.provider.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        try await CodexAuthorization.apply(
            to: &request,
            provider: configuration.provider,
            authStore: configuration.authStore,
            apiKeyStore: configuration.apiKeyStore,
            chatGPTAuthenticator: configuration.chatGPTAuthenticator,
            missingAuthentication: CodexSessionError.missingAuthentication
        )
        request.httpBody = body

        var outputTextByItemID: [String: String] = [:]
        var outputItemOrder: [String] = []
        var fallbackText = ""
        let (bytes, response) = try await configuration.urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try await Self.errorBody(from: bytes)
            throw CodexSessionError.httpStatus(http.statusCode, body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else {
                continue
            }
            let payload = String(line.dropFirst("data: ".count))
            let normalized = try CodexMobileCoreBridge.parseSSEEvent(Data(payload.utf8))
            let event = try Self.decodeStreamEvent(normalized)
            switch event {
            case .outputTextDelta(let itemID, let delta):
                guard !delta.isEmpty else {
                    continue
                }
                if let itemID, !itemID.isEmpty {
                    if outputTextByItemID[itemID] == nil {
                        outputItemOrder.append(itemID)
                        outputTextByItemID[itemID] = ""
                    }
                    outputTextByItemID[itemID, default: ""] += delta
                } else {
                    fallbackText += delta
                }
            case .outputItemCompleted(let item):
                guard item.kind == .assistantMessage,
                      let text = item.text,
                      !text.isEmpty,
                      outputTextByItemID[item.id, default: ""].isEmpty else {
                    continue
                }
                outputItemOrder.append(item.id)
                outputTextByItemID[item.id] = text
            case .completed:
                let joined = outputItemOrder.compactMap { outputTextByItemID[$0] }.joined(separator: "\n")
                return (joined.isEmpty ? fallbackText : joined).trimmingCharacters(in: .whitespacesAndNewlines)
            case .error(let message):
                throw CodexSessionError.compactionUnavailable(message)
            default:
                break
            }
        }

        throw CodexSessionError.compactionUnavailable("Compaction stream closed before completion.")
    }

    static func reasoningParameter(options: CodexTurnOptions?) -> Any {
        if options?.supportsReasoningSummaries == false {
            return NSNull()
        }
        var reasoning: [String: Any] = [:]
        if let reasoningEffort = options?.reasoningEffort {
            reasoning["effort"] = reasoningEffort
        }
        if let reasoningSummary = options?.reasoningSummary,
           reasoningSummary != .none {
            reasoning["summary"] = reasoningSummary.rawValue
        }
        if options?.usesResponsesLite == true {
            reasoning["context"] = "all_turns"
        }
        return reasoning.isEmpty ? NSNull() : reasoning
    }

    static func includeParameter(reasoning: Any) -> [String] {
        reasoning is NSNull ? [] : ["reasoning.encrypted_content"]
    }

    static func textParameter(options: CodexTurnOptions?) -> [String: Any]? {
        guard let verbosity = options?.verbosity else {
            return nil
        }
        return ["verbosity": verbosity.rawValue]
    }

    static func parallelToolCallsParameter(options: CodexTurnOptions?) -> Bool {
        (options?.parallelToolCalls ?? true) && options?.usesResponsesLite != true
    }

    static func subagentTurnOptions(
        arguments: [String: Any],
        parentOptions: CodexTurnOptions?
    ) -> CodexTurnOptions {
        let modelOverride = trimmedNonEmpty(arguments["model"] as? String)
        let inheritsParentModelMetadata = modelOverride == nil || modelOverride == parentOptions?.model
        return CodexTurnOptions(
            model: modelOverride ?? parentOptions?.model,
            reasoningEffort: trimmedNonEmpty(arguments["reasoning_effort"] as? String) ?? parentOptions?.reasoningEffort,
            reasoningSummary: inheritsParentModelMetadata ? parentOptions?.reasoningSummary : nil,
            supportsReasoningSummaries: inheritsParentModelMetadata ? parentOptions?.supportsReasoningSummaries : nil,
            serviceTier: trimmedNonEmpty(arguments["service_tier"] as? String) ?? (inheritsParentModelMetadata ? parentOptions?.serviceTier : nil),
            toolChoice: parentOptions?.toolChoice,
            parallelToolCalls: parentOptions?.parallelToolCalls,
            usesResponsesLite: inheritsParentModelMetadata ? parentOptions?.usesResponsesLite ?? false : false,
            inputModalities: inheritsParentModelMetadata ? parentOptions?.inputModalities : nil,
            verbosity: inheritsParentModelMetadata ? parentOptions?.verbosity : nil,
            availableModelOptions: parentOptions?.availableModelOptions ?? [],
            webSearch: parentOptions?.webSearch
        )
    }

    private func streamOneRequest(
        options: CodexTurnOptions?,
        continuation: AsyncThrowingStream<CodexStreamEvent, Error>.Continuation
    ) async throws -> TurnStreamResult {
        let reasoning = Self.reasoningParameter(options: options)
        var input: [String: Any] = [
            "model": options?.model ?? configuration.model,
            "instructions": buildInstructions(),
            "input": requestInputHistory(),
            "tools": buildToolDefinitions(options: options),
            "stream": true,
            "store": false,
            "reasoning": reasoning,
            "toolChoice": options?.toolChoice ?? "auto",
            "parallelToolCalls": Self.parallelToolCallsParameter(options: options),
            "include": Self.includeParameter(reasoning: reasoning),
            "promptCacheKey": conversationID,
            "metadata": ["codex_client": "CodexKit"],
        ]
        if let serviceTier = options?.serviceTier {
            input["serviceTier"] = serviceTier
        }
        if let text = Self.textParameter(options: options) {
            input["text"] = text
        }
        let body = try CodexMobileCoreBridge.buildResponsesRequest(input)
        input.removeAll(keepingCapacity: false)

        var request = URLRequest(url: configuration.provider.responsesURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in configuration.provider.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        try await CodexAuthorization.apply(
            to: &request,
            provider: configuration.provider,
            authStore: configuration.authStore,
            apiKeyStore: configuration.apiKeyStore,
            chatGPTAuthenticator: configuration.chatGPTAuthenticator,
            missingAuthentication: CodexSessionError.missingAuthentication
        )
        request.httpBody = body

        var activeAssistantItemID: String?
        var fallbackAssistantItemID: String?
        var assistantItemOrder: [String] = []
        var assistantTextsByItemID: [String: String] = [:]
        var toolArgumentDeltasByKey: [String: String] = [:]
        var toolCalls: [CodexToolCall] = []
        let (bytes, response) = try await configuration.urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try await Self.errorBody(from: bytes)
            throw CodexSessionError.httpStatus(http.statusCode, body)
        }

        func assistantItemID(for itemID: String?) -> String {
            if let itemID, !itemID.isEmpty {
                return itemID
            }
            if let activeAssistantItemID {
                return activeAssistantItemID
            }
            if let fallbackAssistantItemID {
                return fallbackAssistantItemID
            }
            let id = "assistant-\(assistantItemOrder.count + 1)"
            fallbackAssistantItemID = id
            return id
        }

        func appendAssistantText(itemID: String, delta: String) {
            guard !delta.isEmpty else {
                return
            }
            if assistantTextsByItemID[itemID] == nil {
                assistantItemOrder.append(itemID)
                assistantTextsByItemID[itemID] = ""
            }
            assistantTextsByItemID[itemID, default: ""] += delta
        }

        func toolArgumentKey(itemID: String?, callID: String?) -> String? {
            if let callID, !callID.isEmpty {
                return callID
            }
            if let itemID, !itemID.isEmpty {
                return itemID
            }
            return nil
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else {
                continue
            }
            let payload = String(line.dropFirst("data: ".count))
            let normalized = try CodexMobileCoreBridge.parseSSEEvent(Data(payload.utf8))
            var event = try Self.decodeStreamEvent(normalized)
            switch event {
            case .outputItemStarted(let item):
                if item.kind == .assistantMessage {
                    activeAssistantItemID = item.id
                    fallbackAssistantItemID = item.id
                }
            case .outputTextDelta(let itemID, let delta):
                let resolvedItemID = assistantItemID(for: itemID)
                appendAssistantText(itemID: resolvedItemID, delta: delta)
                event = .outputTextDelta(itemID: resolvedItemID, delta: delta)
            case .reasoningSummaryDelta(let itemID, let delta):
                let resolvedItemID = itemID ?? activeAssistantItemID
                event = .reasoningSummaryDelta(itemID: resolvedItemID, delta: delta)
            case .toolCallInputDelta(let itemID, let callID, let delta):
                if let key = toolArgumentKey(itemID: itemID, callID: callID) {
                    toolArgumentDeltasByKey[key, default: ""] += delta
                }
            case .outputItemCompleted(let item):
                if item.kind == .assistantMessage {
                    if let text = item.text, !text.isEmpty, assistantTextsByItemID[item.id, default: ""].isEmpty {
                        appendAssistantText(itemID: item.id, delta: text)
                    }
                    if activeAssistantItemID == item.id {
                        activeAssistantItemID = nil
                    }
                    if fallbackAssistantItemID == item.id {
                        fallbackAssistantItemID = nil
                    }
                }
                if let call = CodexSession.toolCall(from: item, argumentDeltas: toolArgumentDeltasByKey) {
                    toolCalls.append(call)
                    if let rawItem = normalized["item"] as? [String: Any] {
                        history.append(rawItem)
                    }
                }
            case .toolCall(let call):
                toolCalls.append(call)
                if let item = normalized["item"] as? [String: Any] {
                    history.append(item)
                }
            case .webSearch:
                if normalized["type"] as? String == "outputItemDone",
                   let item = normalized["item"] as? [String: Any] {
                    history.append(item)
                }
            default:
                break
            }
            continuation.yield(event)
            if case .completed(_, _) = event {
                break
            }
        }

        let assistantTextItems = assistantItemOrder.compactMap { itemID -> AssistantTextItem? in
            guard let text = assistantTextsByItemID[itemID] else {
                return nil
            }
            return AssistantTextItem(itemID: itemID, text: text)
        }
        return TurnStreamResult(assistantTextItems: assistantTextItems, toolCalls: toolCalls)
    }

    private func buildInstructions() -> String {
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

    private func requestInputHistory(
        from items: [[String: Any]]? = nil,
        includeDynamicContext: Bool = true
    ) -> [[String: Any]] {
        let input = Self.requestInputHistory(
            contextualUserInstructions: configuration.contextualUserInstructions,
            history: items ?? history
        )
        guard includeDynamicContext, let subagentContextMessage = subagentEnvironmentContextMessage() else {
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

    private func subagentEnvironmentContextMessage() -> [String: Any]? {
        let statuses = subagents.values
            .sorted { $0.createdOrder < $1.createdOrder }
            .map(Self.subagentStatus)
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

    private static func subagentEnvironmentContextLine(_ status: CodexSubagentStatus) -> String {
        var parts = [
            "- \(escapeEnvironmentContext(status.agentID)): \(escapeEnvironmentContext(subagentContextDisplayName(status)))",
            "path=\(escapeEnvironmentContext(status.path))",
            "status=\(escapeEnvironmentContext(status.status))",
        ]
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

    private static func subagentContextDisplayName(_ status: CodexSubagentStatus) -> String {
        let candidate = status.taskName.isEmpty ? status.path : status.taskName
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? status.agentID
    }

    private static func subagentEnvironmentContextPreview(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let prefix = String(normalized.prefix(maxSubagentEnvironmentContextPreviewCharacters))
        let suffix = normalized.count > maxSubagentEnvironmentContextPreviewCharacters ? "..." : ""
        return escapeEnvironmentContext(prefix + suffix)
    }

    private static func escapeEnvironmentContext(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func buildToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
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

    private func hostedToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
        guard configuration.provider.id == "openai",
              let webSearch = options?.webSearch ?? configuration.webSearch,
              webSearch.isEnabled else {
            return []
        }
        return [webSearch.responsesToolDefinition]
    }

    private static func modelSupportsImages(inputModalities: [String]?) -> Bool {
        guard let inputModalities, !inputModalities.isEmpty else {
            return true
        }
        return inputModalities.contains { $0.lowercased() == "image" }
    }

    static func subagentModelOverrideDescription(options: CodexTurnOptions?) -> String {
        let models = Array(subagentVisibleModelOptions(options: options).prefix(maxSubagentModelOverrideDescriptions))
        guard !models.isEmpty else {
            return "No picker-visible model overrides are currently loaded."
        }

        let lines = models.map { model in
            let efforts = model.supportedReasoningEfforts
                .map { effort in
                    if effort.reasoningEffort == model.defaultReasoningEffort {
                        return "\(effort.reasoningEffort) (default)"
                    }
                    return effort.reasoningEffort
                }
                .joined(separator: ", ")
            let effortsSuffix = efforts.isEmpty ? "" : " Reasoning efforts: \(efforts)."
            let serviceTiers = model.serviceTiers
                .filter { $0.id != "default" }
                .map(\.id)
                .joined(separator: ", ")
            let serviceTierSuffix = serviceTiers.isEmpty ? "" : " Service tiers: \(serviceTiers)."
            let description = model.description.isEmpty ? model.displayName : model.description
            return "- `\(model.model)`: \(description)\(effortsSuffix)\(serviceTierSuffix)"
        }
        return "Available model overrides (optional; inherited parent model is preferred):\n\(lines.joined(separator: "\n"))"
    }

    static func subagentInheritedModelGuidance(options: CodexTurnOptions?) -> String {
        var parts: [String] = []
        if let model = options?.model, !model.isEmpty {
            parts.append("Omit `model` to inherit `\(model)`.")
        }
        if let effort = options?.reasoningEffort, !effort.isEmpty {
            parts.append("Omit `reasoning_effort` to inherit `\(effort)`.")
        }
        if let serviceTier = options?.serviceTier, !serviceTier.isEmpty {
            parts.append("Omit `service_tier` to inherit `\(serviceTier)`.")
        }
        return parts.joined(separator: " ")
    }

    private static func subagentVisibleModelOptions(options: CodexTurnOptions?) -> [CodexModelOption] {
        let models = options?.availableModelOptions ?? []
        var seen: Set<String> = []
        return models.compactMap { model in
            guard !model.isHidden, seen.insert(model.model).inserted else {
                return nil
            }
            return model
        }
    }

    private static func subagentModelOverrideValues(options: CodexTurnOptions?) -> [String] {
        Array(subagentVisibleModelOptions(options: options)
            .map(\.model)
            .prefix(maxSubagentModelOverrideDescriptions))
    }

    private static func subagentReasoningEffortValues(options: CodexTurnOptions?) -> [String] {
        let values = subagentVisibleModelOptions(options: options)
            .flatMap { $0.supportedReasoningEfforts.map(\.reasoningEffort) }
            + [options?.reasoningEffort].compactMap { $0 }
        return orderedUnique(values)
    }

    private static func subagentServiceTierValues(options: CodexTurnOptions?) -> [String] {
        let values = subagentVisibleModelOptions(options: options)
            .flatMap { $0.serviceTiers.map(\.id) }
            .filter { $0 != "default" }
            + [options?.serviceTier].compactMap { $0 }
        return orderedUnique(values)
    }

    static func subagentTurnOptionsValidationError(
        arguments: [String: Any],
        parentOptions: CodexTurnOptions?
    ) -> String? {
        let requestedModel = trimmedNonEmpty(arguments["model"] as? String)
        let requestedReasoningEffort = trimmedNonEmpty(arguments["reasoning_effort"] as? String)
        let requestedServiceTier = trimmedNonEmpty(arguments["service_tier"] as? String)
        guard requestedModel != nil || requestedReasoningEffort != nil || requestedServiceTier != nil else {
            return nil
        }

        let models = subagentVisibleModelOptions(options: parentOptions)
        let selectedModel: CodexModelOption?
        if let requestedModel {
            guard models.isEmpty == false else {
                return nil
            }
            guard let model = models.first(where: { $0.model == requestedModel }) else {
                return "Unknown model `\(requestedModel)` for spawn_agent. Available models: \(availableValuesDescription(models.map(\.model)))."
            }
            selectedModel = model
        } else if let parentModel = trimmedNonEmpty(parentOptions?.model) {
            selectedModel = models.first(where: { $0.model == parentModel })
        } else {
            selectedModel = nil
        }

        if let requestedReasoningEffort {
            if let selectedModel {
                let supported = selectedModel.supportedReasoningEfforts.map(\.reasoningEffort)
                if !supported.isEmpty, !supported.contains(requestedReasoningEffort) {
                    return "Reasoning effort `\(requestedReasoningEffort)` is not supported for model `\(selectedModel.model)`. Supported reasoning efforts: \(availableValuesDescription(supported))."
                }
            } else {
                let supported = subagentReasoningEffortValues(options: parentOptions)
                if !supported.isEmpty, !supported.contains(requestedReasoningEffort) {
                    return "Reasoning effort `\(requestedReasoningEffort)` is not available for spawn_agent. Available reasoning efforts: \(availableValuesDescription(supported))."
                }
            }
        }

        if let requestedServiceTier {
            if let selectedModel {
                let supported = selectedModel.serviceTiers
                    .map(\.id)
                    .filter { $0 != "default" }
                if !supported.contains(requestedServiceTier) {
                    return "Service tier `\(requestedServiceTier)` is not supported for model `\(selectedModel.model)`. Supported service tiers: \(availableValuesDescription(supported))."
                }
            } else {
                let supported = subagentServiceTierValues(options: parentOptions)
                if !supported.isEmpty, !supported.contains(requestedServiceTier) {
                    return "Service tier `\(requestedServiceTier)` is not available for spawn_agent. Available service tiers: \(availableValuesDescription(supported))."
                }
            }
        }

        return nil
    }

    static func subagentSpawnArgumentsValidationError(
        arguments: [String: Any],
        parentOptions: CodexTurnOptions?
    ) -> String? {
        if arguments["fork_context"] != nil {
            return "fork_context is not supported; use fork_turns instead."
        }
        if let forkTurnsError = subagentForkTurnsValidationError(arguments: arguments) {
            return forkTurnsError
        }
        if subagentUsesFullHistoryFork(arguments: arguments) {
            let requestedModel = trimmedNonEmpty(arguments["model"] as? String)
            let requestedReasoningEffort = trimmedNonEmpty(arguments["reasoning_effort"] as? String)
            if requestedModel != nil || requestedReasoningEffort != nil {
                return "Full-history forked agents inherit the parent model and reasoning effort; omit model and reasoning_effort, or spawn with fork_turns set to none or a positive integer string."
            }
        }
        return subagentTurnOptionsValidationError(arguments: arguments, parentOptions: parentOptions)
    }

    private static func subagentForkTurnsValidationError(arguments: [String: Any]) -> String? {
        guard let rawForkTurns = arguments["fork_turns"] else {
            return nil
        }
        guard let forkTurns = rawForkTurns as? String else {
            return "fork_turns must be `none`, `all`, or a positive integer string."
        }
        let normalized = forkTurns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "none", normalized != "all" else {
            return nil
        }
        guard let value = Int(normalized), value > 0 else {
            return "fork_turns must be `none`, `all`, or a positive integer string."
        }
        return nil
    }

    private static func subagentUsesFullHistoryFork(arguments: [String: Any]) -> Bool {
        guard let forkTurns = arguments["fork_turns"] as? String else {
            return true
        }
        let normalized = forkTurns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "all"
    }

    private static func availableValuesDescription(_ values: [String]) -> String {
        let uniqueValues = orderedUnique(values)
        guard !uniqueValues.isEmpty else {
            return "none"
        }
        return uniqueValues.joined(separator: ", ")
    }

    private static func schemaStringProperty(description: String, enumValues: [String]) -> [String: Any] {
        var property: [String: Any] = [
            "type": "string",
            "description": description,
        ]
        if !enumValues.isEmpty {
            property["enum"] = enumValues
        }
        return property
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            guard !value.isEmpty else {
                return false
            }
            return seen.insert(value).inserted
        }
    }

    private static func errorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 16_384 {
                break
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func workspaceInstructions() -> String? {
        guard let workspace = configuration.workspace else {
            return "No workspace is selected. If the user asks about files, say that a workspace must be selected first."
        }
        return """
        Current workspace: \(workspace.rootURL.path)
        Use list_dir, read_file, and search_files to inspect files before answering questions about the workspace. Prefer apply_patch for focused edits and write_file for complete-file writes. Use shell_command or exec_command only when a real shell is needed. Do not claim you have read files unless a tool result has provided their contents.
        """
    }

    private func multiAgentInstructions() -> String? {
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

    private func subagentToolDefinitions(options: CodexTurnOptions?) -> [[String: Any]] {
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
        let spawnAgentDescription = [
            "Spawn a child agent to work on the specified task. The child inherits the same workspace and tools and runs in the background.",
            Self.subagentModelOverrideDescription(options: options),
            Self.subagentInheritedModelGuidance(options: options),
            "The default `fork_turns` is `all`. Full-history forked agents inherit the parent model and reasoning effort; omit `model` and `reasoning_effort` unless `fork_turns` is `none` or a positive integer string.",
            "This session allows up to \(configuration.subagentOptions.maxOpenAgents) open subagents.",
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
                "List live child agents in this session.",
                [
                    "path_prefix": [
                        "type": "string",
                        "description": "Optional canonical task-name prefix filter.",
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

    static func decodeStreamEvent(_ normalized: [String: Any]) throws -> CodexStreamEvent {
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        let type = normalized["type"] as? String
        switch type {
        case "created":
            return .created
        case "outputTextDelta":
            return .outputTextDelta(
                itemID: normalized["itemId"] as? String,
                delta: normalized["delta"] as? String ?? ""
            )
        case "reasoningSummaryDelta":
            return .reasoningSummaryDelta(
                itemID: normalized["itemId"] as? String,
                delta: normalized["delta"] as? String ?? ""
            )
        case "toolCallInputDelta":
            return .toolCallInputDelta(
                itemID: normalized["itemId"] as? String,
                callID: normalized["callId"] as? String,
                delta: normalized["delta"] as? String ?? ""
            )
        case "outputItemAdded":
            if let webSearch = webSearchCall(from: normalized["item"]) {
                return .webSearch(webSearch)
            }
            if let item = outputItem(from: normalized["item"]) {
                return .outputItemStarted(item)
            }
            return .outputItemAdded(normalizedData)
        case "outputItemDone":
            if let webSearch = webSearchCall(from: normalized["item"]) {
                return .webSearch(webSearch)
            }
            if let item = outputItem(from: normalized["item"]) {
                return .outputItemCompleted(item)
            }
            return .outputItemDone(normalizedData)
        case "completed":
            return .completed(normalizedData, CodexTokenUsage.completedResponseUsage(from: normalized))
        case "error":
            return .error(String(decoding: normalizedData, as: UTF8.self))
        default:
            return .raw(normalizedData)
        }
    }

    private static func outputItem(from item: Any?) -> CodexOutputItem? {
        guard
            let item = item as? [String: Any],
            let type = item["type"] as? String
        else {
            return nil
        }
        let role = item["role"] as? String
        let callID = item["call_id"] as? String
        let id = item["id"] as? String ?? callID ?? ""
        guard !id.isEmpty else {
            return nil
        }

        let kind: CodexOutputItem.Kind
        switch type {
        case "message" where role == "assistant":
            kind = .assistantMessage
        case "reasoning":
            kind = .reasoning
        case "function_call":
            kind = .functionCall
        case "custom_tool_call":
            kind = .customToolCall
        case "web_search_call":
            kind = .webSearchCall
        default:
            kind = .unknown
        }

        return CodexOutputItem(
            id: id,
            kind: kind,
            role: role,
            callID: callID,
            name: item["name"] as? String,
            arguments: item["arguments"] as? String ?? item["input"] as? String,
            text: outputText(from: item)
        )
    }

    private static func outputText(from item: [String: Any]) -> String? {
        if let text = item["text"] as? String {
            return text
        }
        guard let content = item["content"] as? [Any] else {
            return nil
        }
        let text = content.compactMap { rawPart -> String? in
            guard let part = rawPart as? [String: Any] else {
                return nil
            }
            let type = part["type"] as? String
            guard type == "output_text" || type == "text" else {
                return nil
            }
            return part["text"] as? String
        }.joined()
        return text.isEmpty ? nil : text
    }

    private static func webSearchCall(from item: Any?) -> CodexWebSearchCall? {
        guard let item = item as? [String: Any],
              item["type"] as? String == "web_search_call",
              let id = item["id"] as? String,
              !id.isEmpty else {
            return nil
        }
        let action = item["action"] as? [String: Any]
        let actionType = action?["type"] as? String ?? "other"
        return CodexWebSearchCall(
            id: id,
            status: item["status"] as? String,
            actionType: actionType,
            detail: webSearchDetail(action: action)
        )
    }

    private static func webSearchDetail(action: [String: Any]?) -> String {
        guard let action else {
            return ""
        }
        switch action["type"] as? String {
        case "search":
            if let query = action["query"] as? String, !query.isEmpty {
                return query
            }
            if let queries = action["queries"] as? [String], !queries.isEmpty {
                return queries.joined(separator: ", ")
            }
        case "open_page":
            if let url = action["url"] as? String {
                return url
            }
        case "find_in_page":
            let pattern = action["pattern"] as? String
            let url = action["url"] as? String
            switch (pattern, url) {
            case (.some(let pattern), .some(let url)):
                return "'\(pattern)' in \(url)"
            case (.some(let pattern), .none):
                return pattern
            case (.none, .some(let url)):
                return url
            case (.none, .none):
                break
            }
        default:
            break
        }
        return ""
    }

    private static func toolCall(from item: Any?) -> CodexToolCall? {
        guard let outputItem = outputItem(from: item) else {
            return nil
        }
        return outputItem.toolCall
    }

    private static func toolCall(
        from item: CodexOutputItem,
        argumentDeltas: [String: String]
    ) -> CodexToolCall? {
        guard
            let callID = item.callID,
            let name = item.name,
            item.kind == .functionCall || item.kind == .customToolCall
        else {
            return nil
        }
        let arguments = item.arguments
            ?? argumentDeltas[callID]
            ?? argumentDeltas[item.id]
            ?? "{}"
        return CodexToolCall(
            itemID: item.id,
            callID: callID,
            name: name,
            arguments: arguments,
            kind: item.kind == .customToolCall ? .custom : .function
        )
    }

    private func executeTool(
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
            return try executeListAgents(call)
        case "close_agent":
            return try await executeCloseAgent(call, subagentStatus: subagentStatus)
        default:
            throw CodexSessionError.unknownTool(call.name)
        }
    }

    private func deniedToolResultIfNeeded(for call: CodexToolCall) async -> CodexToolResult? {
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

    private struct ShellApprovalMetadata {
        let command: String
        let workdir: String?
        let sandboxPermissions: CodexToolSandboxPermissions
        let justification: String?
        let prefixRule: [String]
    }

    private func shellApprovalAlreadyGranted(_ metadata: ShellApprovalMetadata) -> Bool {
        approvedShellPrefixRules.contains { rule in
            Self.command(metadata.command, hasPrefixRule: rule)
        }
    }

    private func rememberShellPrefixRule(_ prefixRule: [String], for metadata: ShellApprovalMetadata) {
        let normalized = Self.normalizedPrefixRule(prefixRule)
        guard metadata.sandboxPermissions == .requireEscalated,
              !normalized.isEmpty,
              Self.command(metadata.command, hasPrefixRule: normalized),
              !approvedShellPrefixRules.contains(normalized) else {
            return
        }
        approvedShellPrefixRules.append(normalized)
    }

    private static func shellApprovalMetadata(for call: CodexToolCall) -> ShellApprovalMetadata? {
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

    private static func normalizedPrefixRule(_ rawValue: Any?) -> [String] {
        guard let values = rawValue as? [Any] else {
            return []
        }
        return normalizedPrefixRule(values.compactMap { $0 as? String })
    }

    private static func normalizedPrefixRule(_ values: [String]) -> [String] {
        values.compactMap { trimmedNonEmpty($0) }
    }

    private static func command(_ command: String, hasPrefixRule prefixRule: [String]) -> Bool {
        let rule = normalizedPrefixRule(prefixRule)
        guard !rule.isEmpty,
              let words = shellWords(from: command),
              words.count >= rule.count else {
            return false
        }
        return Array(words.prefix(rule.count)) == rule
    }

    private static func shellWords(from command: String) -> [String]? {
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

    private static func isShellWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func approvalRequirement(for call: CodexToolCall) -> CodexToolApprovalRequirement {
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

    private func approvalSummary(for call: CodexToolCall, reason: String) -> String {
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

    private func executeListDir(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let dirPath = arguments["dir_path"] as? String ?? "."
        let offset = Self.intValue(arguments["offset"]) ?? 0
        let limit = Self.intValue(arguments["limit"]) ?? 200
        let depth = Self.intValue(arguments["depth"]) ?? 1
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: dirPath)
            let entries = try Self.listDirectory(root: root, target: target, depth: max(depth, 1))
            let page = entries.dropFirst(max(offset, 0)).prefix(max(limit, 1))
            let output = page.isEmpty ? "No entries." : page.joined(separator: "\n")
            return CodexToolResult(output: output)
        }
    }

    private func executeReadFile(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let offset = max(Self.intValue(arguments["offset"]) ?? 0, 0)
        let limit = max(Self.intValue(arguments["limit"]) ?? 400, 1)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return CodexToolResult(output: "\(path): is a directory", success: false)
            }

            let text = try String(contentsOf: target, encoding: .utf8)
            guard arguments["offset"] != nil || arguments["limit"] != nil else {
                if text.count <= 64_000 {
                    return CodexToolResult(output: text)
                }
                let index = text.index(text.startIndex, offsetBy: 64_000)
                return CodexToolResult(output: "\(text[..<index])\n[truncated]")
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else {
                return CodexToolResult(output: "")
            }

            let page = lines.dropFirst(offset).prefix(limit)
            let output = page.joined(separator: "\n")
            if offset + page.count < lines.count {
                return CodexToolResult(output: "\(output)\n[showing lines \(offset + 1)-\(offset + page.count) of \(lines.count)]")
            }
            return CodexToolResult(output: output)
        }
    }

    private func executeSearchFiles(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let query = arguments["query"] as? String ?? arguments["pattern"] as? String ?? ""
        let path = arguments["path"] as? String ?? "."
        let caseSensitive = arguments["case_sensitive"] as? Bool ?? false
        let limit = max(Self.intValue(arguments["limit"]) ?? 100, 1)
        guard !query.isEmpty else {
            return CodexToolResult(output: "Missing query.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            let matches = try Self.searchFiles(
                root: root,
                target: target,
                query: query,
                caseSensitive: caseSensitive,
                limit: limit
            )
            return CodexToolResult(output: matches.isEmpty ? "No matches." : matches.joined(separator: "\n"))
        }
    }

    private func executeShell(
        _ call: CodexToolCall,
        progress: CodexToolProgressHandler? = nil
    ) async throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let command = arguments["command"] as? String ?? arguments["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing command.", success: false)
        }
        if let unsupportedFeature = Self.unsupportedShellExecutionFeature(for: call.name, arguments: arguments) {
            return CodexToolResult(output: unsupportedFeature, success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try await workspace.withSecurityScope { root in
            var input: [String: Any] = [
                "workspaceRoot": root.path,
                "command": command,
                "maxOutputBytes": Self.intValue(arguments["maxOutputBytes"])
                    ?? Self.intValue(arguments["max_output_bytes"])
                    ?? Self.intValue(arguments["max_output_tokens"]).map { $0 * 4 }
                    ?? 64 * 1024,
            ]
            if let workdir = arguments["workdir"] as? String {
                input["workdir"] = workdir
            }
            if let timeoutMilliseconds = Self.intValue(arguments["timeout_ms"]) {
                input["timeout_ms"] = timeoutMilliseconds
            }
            if arguments["login"] != nil {
                input["login"] = Self.boolValue(arguments["login"])
            }
            let response = try await CodexMobileCoreBridge.emulateShell(input) { delta in
                progress?(.outputDelta(delta))
            }
            let exitCode = Self.intValue(response["exit_code"]) ?? 1
            let output = response["output"] as? String ?? ""
            return CodexToolResult(
                output: output.isEmpty ? "(no output)" : output,
                success: exitCode == 0
            )
        }
    }

    private static func unsupportedShellExecutionFeature(for toolName: String, arguments: [String: Any]) -> String? {
        guard toolName == "exec_command" else {
            return nil
        }
        if let sessionID = trimmedNonEmpty(arguments["session_id"] as? String) {
            return "CodexKit exec_command is one-shot and does not support ongoing shell sessions (`session_id`: \(sessionID)). Rerun without session_id; interactive stdin/PTY support requires Codex app-server process execution."
        }
        if boolValue(arguments["tty"]) {
            return "CodexKit exec_command does not support TTY or interactive shell execution. Rerun with tty=false or omit tty."
        }
        return nil
    }

    private func executeApplyPatch(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let patch = arguments["patch"] as? String ?? ""
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing patch.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }
        guard !workspace.readOnly else {
            return CodexToolResult(output: "Workspace is read-only.", success: false)
        }

        return try workspace.withSecurityScope { root in
            var input: [String: Any] = [
                "workspaceRoot": root.path,
                "patch": patch,
                "maxOutputBytes": 64 * 1024,
            ]
            if let workdir = arguments["workdir"] as? String {
                input["workdir"] = workdir
            }
            let response = try CodexMobileCoreBridge.applyPatch(input)
            let exitCode = Self.intValue(response["exit_code"]) ?? 1
            let output = response["output"] as? String ?? ""
            return CodexToolResult(
                output: output.isEmpty ? "(no output)" : output,
                success: exitCode == 0
            )
        }
    }

    private func executeWriteFile(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let content = arguments["content"] as? String ?? ""
        let createDirectories = arguments["create_directories"] as? Bool ?? true
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }
        guard !workspace.readOnly else {
            return CodexToolResult(output: "Workspace is read-only.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveWorkspaceURL(root: root, rawPath: path, mustExist: false)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return CodexToolResult(output: "\(path): is a directory", success: false)
            }

            let parent = target.deletingLastPathComponent()
            if createDirectories {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: parent.path) {
                return CodexToolResult(output: "\(parent.path): no such directory", success: false)
            }

            try content.write(to: target, atomically: true, encoding: .utf8)
            let relativePath = Self.relativeWorkspacePath(root: root, url: target)
            return CodexToolResult(output: "Wrote \(relativePath) (\(content.utf8.count) bytes).")
        }
    }

    private func executeViewImage(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let detail = arguments["detail"] as? String
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard detail == nil || detail == "high" || detail == "original" else {
            return CodexToolResult(
                output: "view_image.detail only supports `high` or `original`; omit `detail` for default high resized behavior, got `\(detail ?? "")`",
                success: false
            )
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return CodexToolResult(output: "\(path): is not an image file", success: false)
            }

            do {
                let image = try Self.imageDataURL(for: target, detail: detail)
                let relativePath = Self.relativeWorkspacePath(root: root, url: target)
                return CodexToolResult(
                    output: "Viewed \(relativePath)",
                    responseOutput: .inputImage(imageURL: image.dataURL, detail: image.detail)
                )
            } catch {
                return CodexToolResult(
                    output: "unable to process image at `\(path)`: \(error.localizedDescription)",
                    success: false
                )
            }
        }
    }

    private func executeUpdatePlan(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let explanation = (arguments["explanation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPlan = arguments["plan"] as? [[String: Any]] else {
            return CodexToolResult(output: "Missing plan.", success: false)
        }

        var items: [CodexPlanItem] = []
        var inProgressCount = 0
        for rawItem in rawPlan {
            let step = (rawItem["step"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !step.isEmpty else {
                return CodexToolResult(output: "update_plan step cannot be empty.", success: false)
            }
            let statusValue = rawItem["status"] as? String ?? ""
            guard let status = CodexPlanItem.Status(rawValue: statusValue) else {
                return CodexToolResult(output: "Unsupported update_plan status: \(statusValue)", success: false)
            }
            if status == .inProgress {
                inProgressCount += 1
            }
            items.append(CodexPlanItem(step: step, status: status))
        }

        guard inProgressCount <= 1 else {
            return CodexToolResult(output: "At most one plan step can be in_progress.", success: false)
        }

        return CodexToolResult(
            output: "Plan updated",
            planUpdate: CodexPlanUpdate(
                explanation: explanation?.isEmpty == true ? nil : explanation,
                items: items
            )
        )
    }

    private func executeSpawnAgent(
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
        if let validationError = Self.subagentSpawnArgumentsValidationError(arguments: arguments, parentOptions: activeTurnOptions) {
            return CodexToolResult(output: validationError, success: false)
        }

        let childPath = Self.subagentPath(parent: agentPath, taskName: taskName)
        guard !subagents.values.contains(where: { $0.path == childPath }) else {
            return CodexToolResult(output: "\(childPath): agent already exists.", success: false)
        }
        let openAgents = subagents.values.filter { !$0.status.isClosed }.count
        guard openAgents < configuration.subagentOptions.maxOpenAgents else {
            return CodexToolResult(
                output: "Subagent limit reached (\(configuration.subagentOptions.maxOpenAgents) open agents).",
                success: false
            )
        }

        subagentSequence += 1
        let id = "agent-\(subagentSequence)"
        let snapshot = try forkedSnapshot(forkTurns: arguments["fork_turns"] as? String)
        let child = CodexSession(configuration: configuration, snapshot: snapshot, agentPath: childPath)
        let options = Self.subagentTurnOptions(arguments: arguments, parentOptions: activeTurnOptions)

        subagents[id] = SubagentRecord(
            id: id,
            taskName: taskName,
            path: childPath,
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

    private func executeSendMessage(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return CodexToolResult(output: "Missing message.", success: false)
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

    private func executeSendInput(
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

    private func executeResumeAgent(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["id"] as? String ?? arguments["target"] as? String ?? ""
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        if record.status.isClosed {
            let openAgents = subagents.values.filter { !$0.status.isClosed }.count
            guard openAgents < configuration.subagentOptions.maxOpenAgents else {
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

    private func executeFollowupTask(
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

    private func executeWaitAgent(_ call: CodexToolCall) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String
        let timeout = waitTimeoutMilliseconds(from: arguments)

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

    private func executeListAgents(_ call: CodexToolCall) throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let prefix = (arguments["path_prefix"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = subagents.values
            .filter { record in
                guard let prefix, !prefix.isEmpty else {
                    return true
                }
                return record.path.hasPrefix(prefix)
            }
            .sorted { $0.createdOrder < $1.createdOrder }
            .map(Self.subagentStatusPayload)
        return CodexToolResult(output: try Self.jsonString(["agents": agents]))
    }

    private func executeCloseAgent(_ call: CodexToolCall, subagentStatus: CodexSubagentStatusHandler?) async throws -> CodexToolResult {
        guard configuration.subagentOptions.isEnabled else {
            return CodexToolResult(output: "Subagents are not enabled for this session.", success: false)
        }
        let arguments = try Self.decodeArguments(call.arguments)
        let target = arguments["target"] as? String ?? ""
        guard let id = subagentID(for: target), var record = subagents[id] else {
            return CodexToolResult(output: "\(target): agent not found.", success: false)
        }
        let previousStatus = record.status
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

    private func appendToolOutput(call: CodexToolCall, result: CodexToolResult) {
        history.append(CodexMobileCoreBridge.toolOutput(
            callID: call.callID,
            output: result.responseOutput?.jsonValue ?? result.output,
            success: result.success,
            custom: call.kind == .custom,
            name: call.name
        ))
    }

    private static func decodeArguments(_ arguments: String) throws -> [String: Any] {
        let data = Data(arguments.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        return value as? [String: Any] ?? [:]
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

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case let value as Int:
            return value != 0
        default:
            return false
        }
    }

    private func forkedSnapshot(forkTurns: String?) throws -> CodexSessionSnapshot {
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

    private func startSubagentTurn(
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

    private func finishSubagentTurn(
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

    private func subagentID(for rawTarget: String) -> String? {
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

    private func waitTimeoutMilliseconds(from arguments: [String: Any]) -> Int {
        let options = configuration.subagentOptions
        let requested = Self.intValue(arguments["timeout_ms"]) ?? options.defaultWaitTimeoutMilliseconds
        return min(max(requested, options.minWaitTimeoutMilliseconds), options.maxWaitTimeoutMilliseconds)
    }

    private static func waitForSubagentTask(
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

    private static func collectFinalText(
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

    private static func subagentPrompt(
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

    private static func subagentStatusPayload(_ record: SubagentRecord) -> [String: Any] {
        subagentStatusPayload(subagentStatus(record))
    }

    private static func subagentStatusPayload(_ status: CodexSubagentStatus) -> [String: Any] {
        var payload: [String: Any] = [
            "agent_id": status.agentID,
            "task_name": status.path,
            "status": status.status,
        ]
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

    private static func subagentStatus(_ record: SubagentRecord) -> CodexSubagentStatus {
        CodexSubagentStatus(
            agentID: record.id,
            taskName: record.taskName,
            path: record.path,
            status: record.status.rawValue,
            finalAnswer: record.status == .completed ? record.finalAnswer ?? "" : nil,
            error: record.status == .failed ? record.errorMessage ?? "Subagent failed." : nil,
            queuedMessages: record.queuedMessages.count,
            queuedFollowups: record.queuedFollowups.count,
            modelSettings: subagentModelSettingsPayload(record.turnOptions)
        )
    }

    private static func subagentModelSettingsPayload(_ options: CodexTurnOptions?) -> [String: String] {
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

    private static func subagentPath(parent: String, taskName: String) -> String {
        parent == "/" ? "/\(taskName)" : "\(parent)/\(taskName)"
    }

    private static func isValidSubagentTaskName(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        return value.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func compactedHistory(summary: String, from history: [[String: Any]]) -> [[String: Any]] {
        let userMessages = compactedUserMessages(from: history)
        let selectedMessages = boundedCompactionUserMessages(userMessages)
        var compacted = selectedMessages.map { message(role: "user", textType: "input_text", text: $0) }
        compacted.append(message(role: "user", textType: "input_text", text: compactionSummaryText(summary)))
        return compacted
    }

    private static func compactedUserMessages(from history: [[String: Any]]) -> [String] {
        history.compactMap { item in
            guard item["type"] as? String == "message",
                  item["role"] as? String == "user",
                  let content = item["content"] as? [Any] else {
                return nil
            }
            let text = content.compactMap { rawPart -> String? in
                guard let part = rawPart as? [String: Any] else {
                    return nil
                }
                let type = part["type"] as? String
                guard type == "input_text" || type == "text" else {
                    return nil
                }
                return part["text"] as? String
            }.joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isCompactionSummaryMessage(trimmed) else {
                return nil
            }
            return trimmed
        }
    }

    private static func boundedCompactionUserMessages(_ messages: [String]) -> [String] {
        var selected: [String] = []
        var remaining = compactUserMessageMaxApproxTokens
        for message in messages.reversed() {
            guard remaining > 0 else {
                break
            }
            let tokens = approximateTokenCount(message)
            if tokens <= remaining {
                selected.append(message)
                remaining -= tokens
            } else {
                selected.append(truncated(message, approximateTokens: remaining))
                break
            }
        }
        return selected.reversed()
    }

    private static func compactionSummaryText(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(no summary available)" : trimmed
        if isCompactionSummaryMessage(body) {
            return body
        }
        return "\(compactionSummaryPrefix)\n\(body)"
    }

    private static func isCompactionSummaryMessage(_ message: String) -> Bool {
        message.hasPrefix("\(compactionSummaryPrefix)\n")
    }

    static func approximateHistoryTokenCount(_ history: [[String: Any]]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: history, options: []) else {
            return 0
        }
        return approximateTokenCount(String(decoding: data, as: UTF8.self))
    }

    private static func approximateTokenCount(_ text: String) -> Int {
        max((text.count + 3) / 4, 1)
    }

    private static func truncated(_ text: String, approximateTokens: Int) -> String {
        let characterLimit = max(approximateTokens, 0) * 4
        guard text.count > characterLimit else {
            return text
        }
        guard characterLimit > 0 else {
            return ""
        }
        let end = text.index(text.startIndex, offsetBy: characterLimit)
        return String(text[..<end])
    }

    private static func message(role: String, textType: String, text: String) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": [["type": textType, "text": text]],
        ]
    }

    private static func resolveExistingWorkspaceURL(root: URL, rawPath: String) throws -> URL {
        try resolveWorkspaceURL(root: root, rawPath: rawPath, mustExist: true)
    }

    private static func resolveWorkspaceURL(root: URL, rawPath: String, mustExist: Bool) throws -> URL {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL
        if rawPath.isEmpty || rawPath == "." {
            candidate = rootURL
        } else if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = rootURL.appending(path: rawPath, directoryHint: .inferFromPath)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard !mustExist || FileManager.default.fileExists(atPath: resolved.path) else {
            throw CodexSessionError.workspacePathError("\(rawPath): no such file or directory")
        }
        guard isInsideWorkspace(url: resolved, root: rootURL) else {
            throw CodexSessionError.workspacePathError("\(rawPath): escapes workspace")
        }
        return resolved
    }

    private static func listDirectory(root: URL, target: URL, depth: Int) throws -> [String] {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexSessionError.workspacePathError("\(target.path): not a directory")
        }

        var results: [String] = []
        try collectDirectoryEntries(root: rootURL, directory: target, remainingDepth: depth, results: &results)
        return results.sorted()
    }

    private static func collectDirectoryEntries(
        root: URL,
        directory: URL,
        remainingDepth: Int,
        results: inout [String]
    ) throws {
        guard remainingDepth > 0 else {
            return
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            let resolved = entry.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideWorkspace(url: resolved, root: root) else {
                continue
            }
            let relative = relativeWorkspacePath(root: root, url: resolved)
            let isDirectory = values.isDirectory == true
            results.append(isDirectory ? "\(relative)/" : relative)
            if isDirectory && values.isSymbolicLink != true {
                try collectDirectoryEntries(
                    root: root,
                    directory: resolved,
                    remainingDepth: remainingDepth - 1,
                    results: &results
                )
            }
        }
    }

    private static func searchFiles(
        root: URL,
        target: URL,
        query: String,
        caseSensitive: Bool,
        limit: Int
    ) throws -> [String] {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls: [URL]

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: target,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = [target]
        }

        let needle = caseSensitive ? query : query.lowercased()
        var matches: [String] = []

        for url in urls {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideWorkspace(url: resolved, root: rootURL) else { continue }
            if let fileSize = values.fileSize, fileSize > 2_000_000 { continue }
            guard let text = try? String(contentsOf: resolved, encoding: .utf8) else { continue }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let haystack = caseSensitive ? String(line) : String(line).lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append("\(relativeWorkspacePath(root: rootURL, url: resolved)):\(index + 1): \(line)")
                if matches.count >= limit {
                    return matches
                }
            }
        }

        return matches
    }

    private static func relativeWorkspacePath(root: URL, url: URL) -> String {
        url.path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func imageDataURL(for url: URL, detail: String?) throws -> (dataURL: String, detail: String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > viewImageMaxBytes {
            throw CodexSessionError.workspacePathError(
                "\(url.lastPathComponent): image is too large (\(fileSize) bytes)"
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): unsupported image file")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let originalMaxDimension = max(width, height)
        guard originalMaxDimension > 0 else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): image has no readable dimensions")
        }

        let usesOriginal = detail == "original"
        let maxPixelDimension = usesOriginal
            ? originalMaxDimension
            : min(originalMaxDimension, viewImageHighMaxPixelDimension)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not decode image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not create image output")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not encode image")
        }

        let encoded = (output as Data).base64EncodedString()
        return ("data:image/png;base64,\(encoded)", usesOriginal ? "original" : "high")
    }

    private static func isInsideWorkspace(url: URL, root: URL) -> Bool {
        let path = url.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

private struct TurnStreamResult {
    let assistantTextItems: [AssistantTextItem]
    let toolCalls: [CodexToolCall]
}

private struct AssistantTextItem {
    let itemID: String
    let text: String
}

private struct SubagentRecord {
    let id: String
    let taskName: String
    let path: String
    let session: CodexSession
    var status: SubagentStatus
    var task: Task<Void, Never>?
    var finalAnswer: String?
    var errorMessage: String?
    var queuedMessages: [String] = []
    var queuedFollowups: [String] = []
    var turnOptions: CodexTurnOptions?
    var statusBeforeClose: SubagentStatus?
    let createdOrder: Int
}

private enum SubagentStatus: String {
    case running
    case completed
    case failed
    case closed

    var isFinal: Bool {
        self == .completed || self == .failed
    }

    var isClosed: Bool {
        self == .closed
    }
}

private final class SubagentWaitRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiter: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func setTasks(waiter: Task<Void, Never>, sleeper: Task<Void, Never>) {
        var shouldCancel = false
        lock.lock()
        if continuation == nil {
            shouldCancel = true
        } else {
            self.waiter = waiter
            self.sleeper = sleeper
        }
        lock.unlock()

        if shouldCancel {
            waiter.cancel()
            sleeper.cancel()
        }
    }

    func finish(_ completed: Bool) {
        let continuationToResume: CheckedContinuation<Bool, Never>?
        let waiterToCancel: Task<Void, Never>?
        let sleeperToCancel: Task<Void, Never>?
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        waiterToCancel = waiter
        sleeperToCancel = sleeper
        waiter = nil
        sleeper = nil
        lock.unlock()

        waiterToCancel?.cancel()
        sleeperToCancel?.cancel()
        continuationToResume?.resume(returning: completed)
    }
}

public enum CodexSessionError: Error, Equatable {
    case missingAuthentication
    case httpStatus(Int, String)
    case unknownTool(String)
    case workspacePathError(String)
    case compactionUnavailable(String)
    case toolLoopLimitExceeded
}
