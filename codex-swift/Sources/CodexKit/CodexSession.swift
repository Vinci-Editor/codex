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
    public let urlSession: URLSession

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
        urlSession: URLSession = .shared
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
        self.urlSession = urlSession
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
    case completed(Data)
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
    private var history: [[String: Any]] = []
    private let toolsByName: [String: any CodexTool]

    public init(configuration: CodexSessionConfiguration) {
        self.configuration = configuration
        self.toolsByName = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
    }

    public init(configuration: CodexSessionConfiguration, snapshot: CodexSessionSnapshot?) {
        self.configuration = configuration
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
        switch configuration.provider.authMode {
        case .none:
            break
        case .chatGPT:
            let tokens = try await chatGPTTokensForRequest()
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = tokens.resolvedChatGPTAccountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
        case .apiKey:
            guard let apiKey = try configuration.apiKeyStore?.loadAPIKey(), !apiKey.isEmpty else {
                throw CodexSessionError.missingAuthentication
            }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
            if case .completed = event {
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
            workspaceInstructions(),
            configuration.additionalDeveloperInstructions,
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func buildToolDefinitions() -> [[String: Any]] {
        CodexMobileCoreBridge.builtinTools() + configuration.tools.map { $0.responsesToolDefinition() }
    }

    private func chatGPTTokensForRequest() async throws -> CodexAuthTokens {
        guard let authStore = configuration.authStore, var tokens = try authStore.loadTokens() else {
            throw CodexSessionError.missingAuthentication
        }
        if tokens.shouldRefresh() {
            let authenticator = configuration.chatGPTAuthenticator ?? CodexDeviceCodeAuthenticator()
            tokens = try await authenticator.refreshTokens(tokens)
            try authStore.saveTokens(tokens)
        }
        return tokens
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
            return .completed(normalizedData)
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
            return try executeShell(call, progress: progress)
        case "apply_patch":
            return try executeApplyPatch(call)
        case "write_file":
            return try executeWriteFile(call)
        default:
            throw CodexSessionError.unknownTool(call.name)
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
    ) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let command = arguments["command"] as? String ?? arguments["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing command.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
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
            let response = try CodexMobileCoreBridge.emulateShell(input) { delta in
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

public enum CodexSessionError: Error, Equatable {
    case missingAuthentication
    case httpStatus(Int, String)
    case unknownTool(String)
    case workspacePathError(String)
    case toolLoopLimitExceeded
}
