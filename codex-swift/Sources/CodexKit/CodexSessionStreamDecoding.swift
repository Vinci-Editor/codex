//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
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

    static func outputItem(from item: Any?) -> CodexOutputItem? {
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

    static func outputText(from item: [String: Any]) -> String? {
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

    static func webSearchCall(from item: Any?) -> CodexWebSearchCall? {
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

    static func webSearchDetail(action: [String: Any]?) -> String {
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

    static func toolCall(from item: Any?) -> CodexToolCall? {
        guard let outputItem = outputItem(from: item) else {
            return nil
        }
        return outputItem.toolCall
    }

    static func toolCall(
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
}
