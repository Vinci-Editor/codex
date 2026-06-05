import Foundation

public struct CodexTokenUsage: Codable, Hashable, Sendable, Equatable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    public let modelContextWindow: Int?

    public init(
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int? = nil,
        modelContextWindow: Int? = nil
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = max(reasoningOutputTokens, 0)
        self.totalTokens = max(totalTokens ?? Self.saturatingAdd(inputTokens, outputTokens), 0)
        self.modelContextWindow = modelContextWindow.map { max($0, 0) }
    }

    public var nonCachedInputTokens: Int {
        max(inputTokens - cachedInputTokens, 0)
    }

    public func adding(_ other: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: Self.saturatingAdd(inputTokens, other.inputTokens),
            cachedInputTokens: Self.saturatingAdd(cachedInputTokens, other.cachedInputTokens),
            outputTokens: Self.saturatingAdd(outputTokens, other.outputTokens),
            reasoningOutputTokens: Self.saturatingAdd(reasoningOutputTokens, other.reasoningOutputTokens),
            totalTokens: Self.saturatingAdd(totalTokens, other.totalTokens),
            modelContextWindow: other.modelContextWindow ?? modelContextWindow
        )
    }
}

extension CodexTokenUsage {
    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = max(lhs, 0).addingReportingOverflow(max(rhs, 0))
        return result.overflow ? Int.max : result.partialValue
    }

    static func completedResponseUsage(from normalized: [String: Any]) -> CodexTokenUsage? {
        let usage = firstDictionary(
            normalized["tokenUsage"],
            normalized["token_usage"],
            dictionary(normalized["response"])["usage"],
            dictionary(normalized["raw"])["usage"],
            dictionary(dictionary(normalized["raw"])["response"])["usage"]
        )
        guard let usage else {
            return nil
        }

        let inputTokens = intValue(usage["input_tokens"]) ?? intValue(usage["inputTokens"])
        let outputTokens = intValue(usage["output_tokens"]) ?? intValue(usage["outputTokens"])
        let totalTokens = intValue(usage["total_tokens"]) ?? intValue(usage["totalTokens"])
        let cachedInputTokens = intValue(usage["cached_input_tokens"])
            ?? intValue(usage["cachedInputTokens"])
            ?? intValue(dictionary(usage["input_tokens_details"])["cached_tokens"])
            ?? intValue(dictionary(usage["inputTokensDetails"])["cachedTokens"])
        let reasoningOutputTokens = intValue(usage["reasoning_output_tokens"])
            ?? intValue(usage["reasoningOutputTokens"])
            ?? intValue(dictionary(usage["output_tokens_details"])["reasoning_tokens"])
            ?? intValue(dictionary(usage["outputTokensDetails"])["reasoningTokens"])
        let modelContextWindow = intValue(usage["model_context_window"])
            ?? intValue(usage["modelContextWindow"])
            ?? intValue(normalized["model_context_window"])
            ?? intValue(normalized["modelContextWindow"])

        guard inputTokens != nil || outputTokens != nil || totalTokens != nil else {
            return nil
        }

        return CodexTokenUsage(
            inputTokens: inputTokens ?? 0,
            cachedInputTokens: cachedInputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            reasoningOutputTokens: reasoningOutputTokens ?? 0,
            totalTokens: totalTokens,
            modelContextWindow: modelContextWindow
        )
    }

    private static func firstDictionary(_ values: Any?...) -> [String: Any]? {
        for value in values {
            let candidate = dictionary(value)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as Double where value.isFinite:
            return Int(value)
        case let value as String:
            return Int(value)
        case _ as Bool:
            return nil
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }
}
