//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func automaticCompactionIfNeeded(options: CodexTurnOptions?) async throws -> CodexCompactionResult? {
        guard let trigger = configuration.compactionOptions.automaticTriggerApproxTokens,
              trigger > 0,
              Self.approximateHistoryTokenCount(history) >= trigger else {
            return nil
        }
        return try await performCompaction(options: options)
    }

    func performCompaction(options: CodexTurnOptions?) async throws -> CodexCompactionResult {
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

    func requestCompactionSummary(
        from baseHistory: [[String: Any]],
        options: CodexTurnOptions?
    ) async throws -> String {
        let compactionInput = await requestInputHistory(from: baseHistory, includeDynamicContext: false) + [
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


    static func compactedHistory(summary: String, from history: [[String: Any]]) -> [[String: Any]] {
        let userMessages = compactedUserMessages(from: history)
        let selectedMessages = boundedCompactionUserMessages(userMessages)
        var compacted = selectedMessages.map { message(role: "user", textType: "input_text", text: $0) }
        compacted.append(message(role: "user", textType: "input_text", text: compactionSummaryText(summary)))
        return compacted
    }

    static func compactedUserMessages(from history: [[String: Any]]) -> [String] {
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

    static func boundedCompactionUserMessages(_ messages: [String]) -> [String] {
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

    static func compactionSummaryText(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(no summary available)" : trimmed
        if isCompactionSummaryMessage(body) {
            return body
        }
        return "\(compactionSummaryPrefix)\n\(body)"
    }

    static func isCompactionSummaryMessage(_ message: String) -> Bool {
        message.hasPrefix("\(compactionSummaryPrefix)\n")
    }

    static func approximateHistoryTokenCount(_ history: [[String: Any]]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: history, options: []) else {
            return 0
        }
        return approximateTokenCount(String(decoding: data, as: UTF8.self))
    }

    static func approximateTokenCount(_ text: String) -> Int {
        max((text.count + 3) / 4, 1)
    }

    static func truncated(_ text: String, approximateTokens: Int) -> String {
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
}
