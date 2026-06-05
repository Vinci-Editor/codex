import Foundation

public struct CodexReasoningEffortOption: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String {
        reasoningEffort
    }

    public let reasoningEffort: String
    public let description: String

    public init(reasoningEffort: String, description: String = "") {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

public struct CodexServiceTierOption: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String = "") {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct CodexModelOption: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let model: String
    public let displayName: String
    public let description: String
    public let defaultReasoningEffort: String?
    public let supportedReasoningEfforts: [CodexReasoningEffortOption]
    public let isHidden: Bool
    public let isDefault: Bool
    public let supportsPersonality: Bool
    public let usesResponsesLite: Bool
    public let inputModalities: [String]
    public let serviceTiers: [CodexServiceTierOption]
    public let defaultServiceTier: String?

    public init(
        id: String,
        model: String,
        displayName: String,
        description: String = "",
        defaultReasoningEffort: String? = nil,
        supportedReasoningEfforts: [CodexReasoningEffortOption] = [],
        isHidden: Bool = false,
        isDefault: Bool = false,
        supportsPersonality: Bool = false,
        usesResponsesLite: Bool = false,
        inputModalities: [String] = ["text"],
        serviceTiers: [CodexServiceTierOption] = [],
        defaultServiceTier: String? = nil
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.supportsPersonality = supportsPersonality
        self.usesResponsesLite = usesResponsesLite
        self.inputModalities = inputModalities
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case description
        case defaultReasoningEffort
        case supportedReasoningEfforts
        case isHidden
        case isDefault
        case supportsPersonality
        case usesResponsesLite
        case inputModalities
        case serviceTiers
        case defaultServiceTier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.model = try container.decode(String.self, forKey: .model)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        self.supportedReasoningEfforts = try container.decodeIfPresent(
            [CodexReasoningEffortOption].self,
            forKey: .supportedReasoningEfforts
        ) ?? []
        self.isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.supportsPersonality = try container.decodeIfPresent(Bool.self, forKey: .supportsPersonality) ?? false
        self.usesResponsesLite = try container.decodeIfPresent(Bool.self, forKey: .usesResponsesLite) ?? false
        self.inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities) ?? ["text"]
        self.serviceTiers = try container.decodeIfPresent([CodexServiceTierOption].self, forKey: .serviceTiers) ?? []
        self.defaultServiceTier = try container.decodeIfPresent(String.self, forKey: .defaultServiceTier)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(supportsPersonality, forKey: .supportsPersonality)
        try container.encode(usesResponsesLite, forKey: .usesResponsesLite)
        try container.encode(inputModalities, forKey: .inputModalities)
        try container.encode(serviceTiers, forKey: .serviceTiers)
        try container.encodeIfPresent(defaultServiceTier, forKey: .defaultServiceTier)
    }

    public static func custom(id: String) -> CodexModelOption {
        CodexModelOption(id: id, model: id, displayName: id)
    }
}

public enum CodexModelCatalogError: Error, Equatable {
    case missingAuthentication
    case httpStatus(Int, String)
    case invalidResponse(String)
}

public final class CodexModelCatalog: @unchecked Sendable {
    private let provider: CodexProvider
    private let authStore: (any CodexAuthStore)?
    private let apiKeyStore: (any CodexAPIKeyStore)?
    private let chatGPTAuthenticator: CodexDeviceCodeAuthenticator?
    private let urlSession: URLSession

    public init(
        provider: CodexProvider,
        authStore: (any CodexAuthStore)? = nil,
        apiKeyStore: (any CodexAPIKeyStore)? = nil,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator? = nil,
        urlSession: URLSession = .shared
    ) {
        self.provider = provider
        self.authStore = authStore
        self.apiKeyStore = apiKeyStore
        self.chatGPTAuthenticator = chatGPTAuthenticator
        self.urlSession = urlSession
    }

    public func listModels(includeHidden: Bool = false) async throws -> [CodexModelOption] {
        var request = URLRequest(url: provider.modelsURL())
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in provider.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        try await CodexAuthorization.apply(
            to: &request,
            provider: provider,
            authStore: authStore,
            apiKeyStore: apiKeyStore,
            chatGPTAuthenticator: chatGPTAuthenticator,
            missingAuthentication: CodexModelCatalogError.missingAuthentication
        )

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CodexModelCatalogError.httpStatus(http.statusCode, String(decoding: data.prefix(16_384), as: UTF8.self))
        }
        return try Self.decodeModelsResponse(data, provider: provider, includeHidden: includeHidden)
    }

    public static func fallbackModels(for provider: CodexProvider) -> [CodexModelOption] {
        switch provider.id {
        case "openai":
            return [
                CodexModelOption(
                    id: "gpt-5.4",
                    model: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Latest frontier agentic coding model.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    isDefault: true,
                    inputModalities: ["text", "image"]
                ),
                CodexModelOption(
                    id: "gpt-5.4-mini",
                    model: "gpt-5.4-mini",
                    displayName: "GPT-5.4 Mini",
                    description: "Smaller frontier agentic coding model.",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"]
                ),
                CodexModelOption(
                    id: "gpt-5.3-codex",
                    model: "gpt-5.3-codex",
                    displayName: "GPT-5.3 Codex",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"]
                ),
                CodexModelOption(
                    id: "gpt-5.2",
                    model: "gpt-5.2",
                    displayName: "GPT-5.2",
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: codexReasoningEfforts,
                    inputModalities: ["text", "image"]
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

    private static let codexReasoningEfforts = [
        CodexReasoningEffortOption(reasoningEffort: "low", description: "Fast responses with lighter reasoning"),
        CodexReasoningEffortOption(reasoningEffort: "medium", description: "Balances speed and reasoning depth"),
        CodexReasoningEffortOption(reasoningEffort: "high", description: "Greater reasoning depth for complex problems"),
        CodexReasoningEffortOption(reasoningEffort: "xhigh", description: "Extra high reasoning depth for complex problems"),
    ]

    private static func decodeCodexBackendModels(
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

    private static func decodeDataModels(
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

    private static func decodeAppServerModel(_ model: [String: Any]) -> CodexModelOption? {
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

    private static func decodeOpenAICompatibleModel(_ model: [String: Any]) -> CodexModelOption? {
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

    private static func finalizedOptions(_ options: [CodexModelOption], includeHidden: Bool) -> [CodexModelOption] {
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
                serviceTiers: option.serviceTiers,
                defaultServiceTier: option.defaultServiceTier
            )
        }
    }

    private static func reasoningEfforts(_ value: Any?) -> [CodexReasoningEffortOption] {
        guard let values = value as? [[String: Any]] else {
            return []
        }
        return values.compactMap { item in
            let effort = string(item["reasoningEffort"]) ?? string(item["effort"])
            guard let normalized = normalizedReasoningEffort(effort) else {
                return nil
            }
            return CodexReasoningEffortOption(
                reasoningEffort: normalized,
                description: string(item["description"]) ?? ""
            )
        }
    }

    private static func serviceTiers(_ value: Any?, additionalSpeedTiers: [String]) -> [CodexServiceTierOption] {
        var tiers: [CodexServiceTierOption] = []
        if let values = value as? [[String: Any]] {
            tiers = values.compactMap { item in
                guard let id = normalizedServiceTier(string(item["id"])) else {
                    return nil
                }
                return CodexServiceTierOption(
                    id: id,
                    name: string(item["name"]) ?? defaultServiceTierName(id),
                    description: string(item["description"]) ?? ""
                )
            }
        }

        var seen = Set(tiers.map(\.id))
        for speedTier in additionalSpeedTiers {
            guard let id = normalizedServiceTier(speedTier),
                  seen.insert(id).inserted else {
                continue
            }
            tiers.append(CodexServiceTierOption(
                id: id,
                name: defaultServiceTierName(id),
                description: ""
            ))
        }
        return tiers
    }

    private static func normalizedServiceTier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let normalized = value.lowercased()
        switch normalized {
        case "fast":
            return "priority"
        default:
            return normalized
        }
    }

    private static func defaultServiceTierName(_ id: String) -> String {
        switch id {
        case "priority":
            return "Priority"
        case "flex":
            return "Flex"
        case "default":
            return "Standard"
        default:
            return id
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private static func sortByPriority(_ lhs: DecodedModel, _ rhs: DecodedModel) -> Bool {
        switch (lhs.priority, rhs.priority) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.option.displayName.localizedStandardCompare(rhs.option.displayName) == .orderedAscending
        }
    }

    private static func normalizedReasoningEffort(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func stringArray(_ value: Any?, fallback: [String]) -> [String] {
        guard let values = value as? [Any] else {
            return fallback
        }
        let strings = values.compactMap(string)
        return strings.isEmpty ? fallback : strings
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty:
            return value
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return value == "true"
        case let value as Int:
            return value != 0
        default:
            return false
        }
    }

    private static func int(_ value: Any?) -> Int? {
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

    private struct DecodedModel {
        let option: CodexModelOption
        let priority: Int?
    }
}
