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
    public let supportsReasoningSummaries: Bool?
    public let defaultReasoningSummary: CodexReasoningSummary?
    public let supportsVerbosity: Bool?
    public let defaultVerbosity: CodexVerbosity?
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
        supportsReasoningSummaries: Bool? = nil,
        defaultReasoningSummary: CodexReasoningSummary? = nil,
        supportsVerbosity: Bool? = nil,
        defaultVerbosity: CodexVerbosity? = nil,
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
        self.supportsReasoningSummaries = supportsReasoningSummaries
        self.defaultReasoningSummary = defaultReasoningSummary
        self.supportsVerbosity = supportsVerbosity
        self.defaultVerbosity = defaultVerbosity
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
        case supportsReasoningSummaries
        case defaultReasoningSummary
        case supportsVerbosity
        case defaultVerbosity
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
        self.supportsReasoningSummaries = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningSummaries)
        self.defaultReasoningSummary = try container.decodeIfPresent(
            CodexReasoningSummary.self,
            forKey: .defaultReasoningSummary
        )
        self.supportsVerbosity = try container.decodeIfPresent(Bool.self, forKey: .supportsVerbosity)
        self.defaultVerbosity = try container.decodeIfPresent(CodexVerbosity.self, forKey: .defaultVerbosity)
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
        try container.encodeIfPresent(supportsReasoningSummaries, forKey: .supportsReasoningSummaries)
        try container.encodeIfPresent(defaultReasoningSummary, forKey: .defaultReasoningSummary)
        try container.encodeIfPresent(supportsVerbosity, forKey: .supportsVerbosity)
        try container.encodeIfPresent(defaultVerbosity, forKey: .defaultVerbosity)
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
}
