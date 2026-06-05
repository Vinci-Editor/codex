//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func runTurn(
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
        parentOptions: CodexTurnOptions?,
        role: CodexSubagentRole? = nil
    ) -> CodexTurnOptions {
        let modelOverride = role?.model ?? trimmedNonEmpty(arguments["model"] as? String)
        let reasoningEffort = role?.reasoningEffort
            ?? trimmedNonEmpty(arguments["reasoning_effort"] as? String)
            ?? parentOptions?.reasoningEffort
        let serviceTier = role?.serviceTier
            ?? trimmedNonEmpty(arguments["service_tier"] as? String)
            ?? parentOptions?.serviceTier
        let inheritsParentModelMetadata = modelOverride == nil || modelOverride == parentOptions?.model
        return CodexTurnOptions(
            model: modelOverride ?? parentOptions?.model,
            reasoningEffort: reasoningEffort,
            reasoningSummary: inheritsParentModelMetadata ? parentOptions?.reasoningSummary : nil,
            supportsReasoningSummaries: inheritsParentModelMetadata ? parentOptions?.supportsReasoningSummaries : nil,
            serviceTier: inheritsParentModelMetadata ? serviceTier : role?.serviceTier ?? trimmedNonEmpty(arguments["service_tier"] as? String),
            toolChoice: parentOptions?.toolChoice,
            parallelToolCalls: parentOptions?.parallelToolCalls,
            usesResponsesLite: inheritsParentModelMetadata ? parentOptions?.usesResponsesLite ?? false : false,
            inputModalities: inheritsParentModelMetadata ? parentOptions?.inputModalities : nil,
            verbosity: inheritsParentModelMetadata ? parentOptions?.verbosity : nil,
            availableModelOptions: parentOptions?.availableModelOptions ?? [],
            webSearch: parentOptions?.webSearch
        )
    }

    func streamOneRequest(
        options: CodexTurnOptions?,
        continuation: AsyncThrowingStream<CodexStreamEvent, Error>.Continuation
    ) async throws -> TurnStreamResult {
        let reasoning = Self.reasoningParameter(options: options)
        let requestHistory = await requestInputHistory()
        var input: [String: Any] = [
            "model": options?.model ?? configuration.model,
            "instructions": buildInstructions(),
            "input": requestHistory,
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
}
