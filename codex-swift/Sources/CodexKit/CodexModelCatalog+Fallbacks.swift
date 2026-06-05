//
//  CodexModelCatalog+Fallbacks.swift
//  CodexKit
//
//  Created by Ethan Lipnik.
//

import Foundation

extension CodexModelCatalog {
    public static func fallbackModels(for provider: CodexProvider) -> [CodexModelOption] {
        switch provider.id {
        case "openai", "openai-api":
            return [
                CodexModelOption(
                    id: "gpt-5.5",
                    model: "gpt-5.5",
                    displayName: "GPT-5.5",
                    description: "Frontier model for complex coding, research, and real-world work.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    isDefault: true,
                    inputModalities: ["text", "image"],
                    supportsReasoningSummaries: true,
                    defaultReasoningSummary: CodexReasoningSummary.none,
                    supportsVerbosity: true,
                    defaultVerbosity: .low
                ),
                CodexModelOption(
                    id: "gpt-5.4",
                    model: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Strong model for everyday coding.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"],
                    supportsReasoningSummaries: true,
                    defaultReasoningSummary: CodexReasoningSummary.none,
                    supportsVerbosity: true,
                    defaultVerbosity: .low
                ),
                CodexModelOption(
                    id: "gpt-5.4-mini",
                    model: "gpt-5.4-mini",
                    displayName: "GPT-5.4 Mini",
                    description: "Small, fast, and cost-efficient model for simpler coding tasks.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"],
                    supportsReasoningSummaries: true,
                    defaultReasoningSummary: CodexReasoningSummary.none,
                    supportsVerbosity: true,
                    defaultVerbosity: .medium
                ),
                CodexModelOption(
                    id: "gpt-5.3-codex",
                    model: "gpt-5.3-codex",
                    displayName: "GPT-5.3 Codex",
                    description: "Coding-optimized model.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"],
                    supportsReasoningSummaries: true,
                    defaultReasoningSummary: CodexReasoningSummary.none,
                    supportsVerbosity: true,
                    defaultVerbosity: .low
                ),
                CodexModelOption(
                    id: "gpt-5.2",
                    model: "gpt-5.2",
                    displayName: "GPT-5.2",
                    description: "Optimized for professional work and long-running agents.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"],
                    supportsReasoningSummaries: true,
                    defaultReasoningSummary: .auto,
                    supportsVerbosity: true,
                    defaultVerbosity: .low
                ),
            ]
        case "lmstudio":
            return [
                CodexModelOption(id: "local-model", model: "local-model", displayName: "Local Model", isDefault: true),
                CodexModelOption(id: "openai/gpt-oss-20b", model: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B"),
                CodexModelOption(id: "qwen/qwen3-coder", model: "qwen/qwen3-coder", displayName: "Qwen3 Coder"),
            ]
        case "ollama":
            return [
                CodexModelOption(id: "local-model", model: "local-model", displayName: "Local Model", isDefault: true),
                CodexModelOption(id: "gpt-oss:20b", model: "gpt-oss:20b", displayName: "GPT-OSS 20B"),
                CodexModelOption(id: "qwen3-coder", model: "qwen3-coder", displayName: "Qwen3 Coder"),
            ]
        default:
            return []
        }
    }

    public static func defaultModel(for provider: CodexProvider, currentModel: String? = nil) -> String {
        let fallback = fallbackModels(for: provider)
        return fallback.first(where: \.isDefault)?.model ?? fallback.first?.model ?? currentModel ?? ""
    }
}
