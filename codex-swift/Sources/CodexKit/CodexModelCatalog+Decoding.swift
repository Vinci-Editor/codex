//
//  CodexModelCatalog+Decoding.swift
//  CodexKit
//
//  Created by Ethan Lipnik.
//

import Foundation

extension CodexModelCatalog {
    static func decodeModelsResponse(
        _ data: Data,
        provider: CodexProvider,
        includeHidden: Bool = false
    ) throws -> [CodexModelOption] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let object = object as? [String: Any] else {
            throw CodexModelCatalogError.invalidResponse("Expected top-level object.")
        }
        if let models = object["models"] as? [[String: Any]] {
            return try decodeCodexBackendModels(models, provider: provider, includeHidden: includeHidden)
        }
        if let data = object["data"] as? [[String: Any]] {
            return try decodeDataModels(data, includeHidden: includeHidden)
        }
        throw CodexModelCatalogError.invalidResponse("Expected models or data array.")
    }

    static let codexReasoningEfforts = [
        CodexReasoningEffortOption(reasoningEffort: "low", description: "Fast responses with lighter reasoning"),
        CodexReasoningEffortOption(reasoningEffort: "medium", description: "Balances speed and reasoning depth"),
        CodexReasoningEffortOption(reasoningEffort: "high", description: "Greater reasoning depth for complex problems"),
        CodexReasoningEffortOption(reasoningEffort: "xhigh", description: "Extra high reasoning depth for complex problems"),
    ]

    static func decodeCodexBackendModels(
        _ models: [[String: Any]],
        provider: CodexProvider,
        includeHidden: Bool
    ) throws -> [CodexModelOption] {
        let chatGPTMode = provider.authMode == .chatGPT
        let decoded = models.compactMap { model -> DecodedModel? in
            guard chatGPTMode || bool(model["supported_in_api"]) else {
                return nil
            }
            guard let id = string(model["slug"]) else {
                return nil
            }
            let visibility = string(model["visibility"]) ?? "list"
            return DecodedModel(
                option: CodexModelOption(
                    id: id,
                    model: id,
                    displayName: string(model["display_name"]) ?? id,
                    description: string(model["description"]) ?? "",
                    defaultReasoningEffort: normalizedReasoningEffort(string(model["default_reasoning_level"])),
                    supportedReasoningEfforts: reasoningEfforts(model["supported_reasoning_levels"]),
                    isHidden: visibility != "list",
                    supportsPersonality: bool(model["supports_personality"]),
                    usesResponsesLite: bool(model["use_responses_lite"]),
                    inputModalities: stringArray(model["input_modalities"], fallback: ["text"]),
                    supportsReasoningSummaries: optionalBool(model["supports_reasoning_summaries"]),
                    defaultReasoningSummary: normalizedReasoningSummary(string(model["default_reasoning_summary"])),
                    supportsVerbosity: optionalBool(model["support_verbosity"]),
                    defaultVerbosity: normalizedVerbosity(string(model["default_verbosity"])),
                    serviceTiers: serviceTiers(
                        model["service_tiers"],
                        additionalSpeedTiers: stringArray(model["additional_speed_tiers"], fallback: [])
                    ),
                    defaultServiceTier: normalizedServiceTier(string(model["default_service_tier"]))
                ),
                priority: int(model["priority"])
            )
        }
        .sorted(by: sortByPriority)
        return finalizedOptions(decoded.map(\.option), includeHidden: includeHidden)
    }

    static func decodeDataModels(
        _ models: [[String: Any]],
        includeHidden: Bool
    ) throws -> [CodexModelOption] {
        let hasCodexShape = models.contains { model in
            model["displayName"] != nil || model["supportedReasoningEfforts"] != nil || model["defaultReasoningEffort"] != nil
        }
        if hasCodexShape {
            return finalizedOptions(models.compactMap(decodeAppServerModel), includeHidden: includeHidden)
        }
        return finalizedOptions(models.compactMap(decodeOpenAICompatibleModel), includeHidden: includeHidden)
    }

    static func decodeAppServerModel(_ model: [String: Any]) -> CodexModelOption? {
        guard let id = string(model["id"]) ?? string(model["model"]) else {
            return nil
        }
        return CodexModelOption(
            id: id,
            model: string(model["model"]) ?? id,
            displayName: string(model["displayName"]) ?? id,
            description: string(model["description"]) ?? "",
            defaultReasoningEffort: normalizedReasoningEffort(string(model["defaultReasoningEffort"])),
            supportedReasoningEfforts: reasoningEfforts(model["supportedReasoningEfforts"]),
            isHidden: bool(model["hidden"]),
            isDefault: bool(model["isDefault"]),
            supportsPersonality: bool(model["supportsPersonality"]),
            usesResponsesLite: bool(model["usesResponsesLite"])
                || bool(model["useResponsesLite"])
                || bool(model["use_responses_lite"]),
            inputModalities: stringArray(model["inputModalities"], fallback: ["text"]),
            supportsReasoningSummaries: optionalBool(
                model["supportsReasoningSummaries"] ?? model["supports_reasoning_summaries"]
            ),
            defaultReasoningSummary: normalizedReasoningSummary(
                string(model["defaultReasoningSummary"]) ?? string(model["default_reasoning_summary"])
            ),
            supportsVerbosity: optionalBool(
                model["supportsVerbosity"] ?? model["supportVerbosity"] ?? model["support_verbosity"]
            ),
            defaultVerbosity: normalizedVerbosity(
                string(model["defaultVerbosity"]) ?? string(model["default_verbosity"])
            ),
            serviceTiers: serviceTiers(
                model["serviceTiers"] ?? model["service_tiers"],
                additionalSpeedTiers: stringArray(
                    model["additionalSpeedTiers"] ?? model["additional_speed_tiers"],
                    fallback: []
                )
            ),
            defaultServiceTier: normalizedServiceTier(
                string(model["defaultServiceTier"]) ?? string(model["default_service_tier"])
            )
        )
    }

    static func decodeOpenAICompatibleModel(_ model: [String: Any]) -> CodexModelOption? {
        guard let id = string(model["id"]) else {
            return nil
        }
        return CodexModelOption(
            id: id,
            model: id,
            displayName: string(model["display_name"]) ?? string(model["name"]) ?? id,
            description: string(model["description"]) ?? "",
            inputModalities: ["text"]
        )
    }

    static func finalizedOptions(_ options: [CodexModelOption], includeHidden: Bool) -> [CodexModelOption] {
        let filtered = options.filter { includeHidden || !$0.isHidden }
        guard !filtered.isEmpty else {
            return []
        }
        let defaultID = filtered.first(where: \.isDefault)?.id
            ?? filtered.first(where: { !$0.isHidden })?.id
            ?? filtered.first?.id
        return filtered.map { option in
            CodexModelOption(
                id: option.id,
                model: option.model,
                displayName: option.displayName,
                description: option.description,
                defaultReasoningEffort: option.defaultReasoningEffort,
                supportedReasoningEfforts: option.supportedReasoningEfforts,
                isHidden: option.isHidden,
                isDefault: option.id == defaultID,
                supportsPersonality: option.supportsPersonality,
                usesResponsesLite: option.usesResponsesLite,
                inputModalities: option.inputModalities,
                supportsReasoningSummaries: option.supportsReasoningSummaries,
                defaultReasoningSummary: option.defaultReasoningSummary,
                supportsVerbosity: option.supportsVerbosity,
                defaultVerbosity: option.defaultVerbosity,
                serviceTiers: option.serviceTiers,
                defaultServiceTier: option.defaultServiceTier
            )
        }
    }
}
