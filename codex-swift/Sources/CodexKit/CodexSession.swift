import Foundation
import CodexMobileCoreBridge

public struct CodexSessionConfiguration: Sendable {
    public let provider: CodexProvider
    public let model: String
    public let authStore: (any CodexAuthStore)?
    public let apiKeyStore: (any CodexAPIKeyStore)?
    public let chatGPTAuthenticator: CodexDeviceCodeAuthenticator?
    public let workspace: CodexWorkspace?
    public let baseInstructionsOverride: String?
    public let additionalDeveloperInstructions: String?
    public let tools: [any CodexTool]
    public let subagentOptions: CodexSubagentOptions
    public let urlSession: URLSession
    public let toolApprovalHandler: CodexToolApprovalHandler?

    public init(
        provider: CodexProvider = .openAI,
        model: String = "gpt-5.4",
        authStore: (any CodexAuthStore)? = nil,
        apiKeyStore: (any CodexAPIKeyStore)? = nil,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator? = nil,
        workspace: CodexWorkspace? = nil,
        baseInstructionsOverride: String? = nil,
        additionalDeveloperInstructions: String? = nil,
        tools: [any CodexTool] = [],
        subagentOptions: CodexSubagentOptions = .disabled,
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
        self.tools = tools
        self.subagentOptions = subagentOptions
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
            tools: tools,
            subagentOptions: subagentOptions,
            urlSession: urlSession,
            toolApprovalHandler: handler
        )
    }
}

public struct CodexOutputItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case assistantMessage
        case reasoning
        case functionCall
        case customToolCall
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
    case toolCall(CodexToolCall)
    case toolResult(CodexToolCall, String, Bool)
    case error(String)
    case raw(Data)
}

public struct CodexSessionSnapshot: Codable, Sendable, Equatable, Hashable {
    public let historyJSON: Data

    public init(historyJSON: Data) {
        self.historyJSON = historyJSON
    }
}

public actor CodexSession {
    private let configuration: CodexSessionConfiguration
    private let conversationID = UUID().uuidString
    private let agentPath: String
    private var history: [[String: Any]] = []
    private let toolsByName: [String: any CodexTool]
    private var subagents: [String: SubagentRecord] = [:]
    private var subagentSequence = 0

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

    public func executeToolCall(_ call: CodexToolCall) async throws -> Data {
        let result = try await executeTool(call)
        appendToolOutput(call: call, result: result)
        return try JSONSerialization.data(
            withJSONObject: CodexMobileCoreBridge.toolOutput(
                callID: call.callID,
                output: result.output,
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
                let toolResult = try await executeTool(call) { progress in
                    guard let delta = progress.outputDelta, !delta.isEmpty else {
                        return
                    }
                    continuation.yield(.toolOutputDelta(call, delta))
                }
                appendToolOutput(call: call, result: toolResult)
                continuation.yield(.toolResult(call, toolResult.output, toolResult.success))
            }
        }

        throw CodexSessionError.toolLoopLimitExceeded
    }

    private func streamOneRequest(
        options: CodexTurnOptions?,
        continuation: AsyncThrowingStream<CodexStreamEvent, Error>.Continuation
    ) async throws -> TurnStreamResult {
        let reasoning: Any
        if let reasoningEffort = options?.reasoningEffort {
            reasoning = ["effort": reasoningEffort]
        } else {
            reasoning = NSNull()
        }
        var input: [String: Any] = [
            "model": options?.model ?? configuration.model,
            "instructions": buildInstructions(),
            "input": history,
            "tools": buildToolDefinitions(),
            "stream": true,
            "store": false,
            "reasoning": reasoning,
            "toolChoice": options?.toolChoice ?? "auto",
            "parallelToolCalls": options?.parallelToolCalls ?? true,
            "promptCacheKey": conversationID,
            "metadata": ["codex_client": "CodexKit"],
        ]
        if let serviceTier = options?.serviceTier {
            input["serviceTier"] = serviceTier
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

    private func buildToolDefinitions() -> [[String: Any]] {
        CodexMobileCoreBridge.builtinTools()
            + subagentToolDefinitions()
            + configuration.tools.map { $0.responsesToolDefinition() }
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

            You can use `spawn_agent` to create a child agent, `followup_task` to give an existing child agent a new task and trigger a turn, `send_message` to pass a message to an existing child without triggering a turn, `wait_agent` to wait for child output, `list_agents` to inspect live child agents, and `close_agent` to close agents that are no longer needed. Use subagents only when delegation or parallel work materially helps the user request.
            """
        }
        return """
        You are `\(agentPath)`, a child agent in a team of agents collaborating to complete a task.

        You can use `spawn_agent` to create a child agent, `followup_task` to give an existing child agent a new task and trigger a turn, `send_message` to pass a message to an existing child without triggering a turn, `wait_agent` to wait for child output, `list_agents` to inspect live child agents, and `close_agent` to close agents that are no longer needed. When you provide a final answer, that content is delivered back to your parent agent.
        """
    }

    private func subagentToolDefinitions() -> [[String: Any]] {
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

        return [
            tool(
                "spawn_agent",
                "Spawn a child agent to work on the specified task. The child inherits the same workspace and tools and runs in the background.",
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
                        "description": "Optional history fork depth. Use none, all, or a positive integer string.",
                    ],
                    "model": [
                        "type": "string",
                        "description": "Optional model override. Omit to inherit the parent session model.",
                    ],
                    "reasoning_effort": [
                        "type": "string",
                        "description": "Optional reasoning effort override. Omit to inherit the parent turn default.",
                    ],
                    "service_tier": [
                        "type": "string",
                        "description": "Optional service tier override.",
                    ],
                ],
                required: ["task_name", "message"]
            ),
            tool(
                "send_message",
                "Send a message to an existing agent without triggering a new turn.",
                ["target": targetProperty, "message": messageProperty],
                required: ["target", "message"]
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
            if let item = outputItem(from: normalized["item"]) {
                return .outputItemStarted(item)
            }
            return .outputItemAdded(normalizedData)
        case "outputItemDone":
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
        progress: CodexToolProgressHandler? = nil
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
        case "spawn_agent":
            return try await executeSpawnAgent(call)
        case "send_message":
            return try executeSendMessage(call)
        case "followup_task":
            return try await executeFollowupTask(call)
        case "wait_agent":
            return try await executeWaitAgent(call)
        case "list_agents":
            return try executeListAgents(call)
        case "close_agent":
            return try executeCloseAgent(call)
        default:
            throw CodexSessionError.unknownTool(call.name)
        }
    }

    private func deniedToolResultIfNeeded(for call: CodexToolCall) async -> CodexToolResult? {
        guard case .required(let reason) = approvalRequirement(for: call) else {
            return nil
        }

        let request = CodexToolApprovalRequest(
            call: call,
            reason: reason,
            summary: approvalSummary(for: call, reason: reason)
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
        case .deny(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexToolResult(
                output: trimmed.isEmpty ? "Denied \(call.name)." : "Denied \(call.name): \(trimmed)",
                success: false
            )
        }
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

    private func executeSpawnAgent(_ call: CodexToolCall) async throws -> CodexToolResult {
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
        let options = CodexTurnOptions(
            model: arguments["model"] as? String,
            reasoningEffort: arguments["reasoning_effort"] as? String,
            serviceTier: arguments["service_tier"] as? String
        )

        subagents[id] = SubagentRecord(
            id: id,
            taskName: taskName,
            path: childPath,
            session: child,
            status: .running,
            turnOptions: options,
            createdOrder: subagentSequence
        )
        startSubagentTurn(id: id, message: message, options: options)

        return CodexToolResult(output: try Self.jsonString([
            "agent_id": id,
            "task_name": childPath,
        ]))
    }

    private func executeSendMessage(_ call: CodexToolCall) throws -> CodexToolResult {
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
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "status": "queued",
        ]))
    }

    private func executeFollowupTask(_ call: CodexToolCall) async throws -> CodexToolResult {
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
            return CodexToolResult(output: try Self.jsonString([
                "target": record.path,
                "status": "queued",
            ]))
        }

        subagents[id] = record
        startSubagentTurn(id: id, message: message, options: record.turnOptions)
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

    private func executeCloseAgent(_ call: CodexToolCall) throws -> CodexToolResult {
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
        record.status = .closed
        subagents[id] = record
        return CodexToolResult(output: try Self.jsonString([
            "target": record.path,
            "previous_status": previousStatus.rawValue,
            "status": record.status.rawValue,
        ]))
    }

    private func appendToolOutput(call: CodexToolCall, result: CodexToolResult) {
        history.append(CodexMobileCoreBridge.toolOutput(
            callID: call.callID,
            output: result.output,
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

    private func startSubagentTurn(id: String, message: String, options: CodexTurnOptions?) {
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
        let task = Task.detached { [child, options] in
            do {
                let output = try await Self.collectFinalText(from: child.submit(userText: prompt, options: options))
                await self.finishSubagentTurn(id: id, finalAnswer: output, errorMessage: nil)
            } catch is CancellationError {
                await self.finishSubagentTurn(id: id, finalAnswer: nil, errorMessage: "cancelled")
            } catch {
                await self.finishSubagentTurn(id: id, finalAnswer: nil, errorMessage: error.localizedDescription)
            }
        }
        record.task = task
        subagents[id] = record
    }

    private func finishSubagentTurn(id: String, finalAnswer: String?, errorMessage: String?) {
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
            startSubagentTurn(id: id, message: next, options: options)
            return
        }

        subagents[id] = record
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
        from stream: AsyncThrowingStream<CodexStreamEvent, Error>
    ) async throws -> String {
        var outputTextByItemID: [String: String] = [:]
        var order: [String] = []
        var fallbackText = ""

        for try await event in stream {
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

    private static func subagentStatusPayload(_ record: SubagentRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "agent_id": record.id,
            "task_name": record.path,
            "status": record.status.rawValue,
        ]
        switch record.status {
        case .completed:
            payload["final_answer"] = record.finalAnswer ?? ""
        case .failed:
            payload["error"] = record.errorMessage ?? "Subagent failed."
        default:
            break
        }
        if !record.queuedMessages.isEmpty {
            payload["queued_messages"] = record.queuedMessages.count
        }
        if !record.queuedFollowups.isEmpty {
            payload["queued_followups"] = record.queuedFollowups.count
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
    case toolLoopLimitExceeded
}
