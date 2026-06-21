import Foundation

public enum CodexWebSearchMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case disabled
    case cached
    case live

    public var id: String {
        rawValue
    }
}

public enum CodexWebSearchContextSize: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case low
    case medium
    case high
}

public enum CodexReasoningSummary: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case auto
    case concise
    case detailed
    case none

    public var id: String {
        rawValue
    }
}

public enum CodexVerbosity: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case low
    case medium
    case high

    public var id: String {
        rawValue
    }
}

public struct CodexWebSearchOptions: Codable, Sendable, Equatable, Hashable {
    public let mode: CodexWebSearchMode
    public let searchContextSize: CodexWebSearchContextSize?
    public let allowedDomains: [String]

    public init(
        mode: CodexWebSearchMode = .cached,
        searchContextSize: CodexWebSearchContextSize? = nil,
        allowedDomains: [String] = []
    ) {
        self.mode = mode
        self.searchContextSize = searchContextSize
        self.allowedDomains = allowedDomains
    }

    var isEnabled: Bool {
        mode != .disabled
    }

    var responsesToolDefinition: [String: Any] {
        var tool: [String: Any] = [
            "type": "web_search",
            "external_web_access": mode == .live,
        ]
        if let searchContextSize {
            tool["search_context_size"] = searchContextSize.rawValue
        }
        if !allowedDomains.isEmpty {
            tool["filters"] = ["allowed_domains": allowedDomains]
        }
        return tool
    }
}

public struct CodexTurnOptions: Sendable, Equatable {
    public let model: String?
    public let reasoningEffort: String?
    public let reasoningSummary: CodexReasoningSummary?
    public let supportsReasoningSummaries: Bool?
    public let serviceTier: String?
    public let toolChoice: String?
    public let parallelToolCalls: Bool?
    public let usesResponsesLite: Bool
    public let inputModalities: [String]?
    public let verbosity: CodexVerbosity?
    public let availableModelOptions: [CodexModelOption]
    public let webSearch: CodexWebSearchOptions?
    /// Maximum number of model round-trips (tool-calling iterations) allowed in a
    /// single turn. `nil` means unlimited — the turn runs until the model stops
    /// requesting tools, matching the codex-rs reference behavior. A finite value
    /// throws `CodexSessionError.toolLoopLimitExceeded` once reached.
    public let maxToolIterations: Int?

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        reasoningSummary: CodexReasoningSummary? = nil,
        supportsReasoningSummaries: Bool? = nil,
        serviceTier: String? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool? = nil,
        usesResponsesLite: Bool = false,
        inputModalities: [String]? = nil,
        verbosity: CodexVerbosity? = nil,
        availableModelOptions: [CodexModelOption] = [],
        webSearch: CodexWebSearchOptions? = nil,
        maxToolIterations: Int? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.supportsReasoningSummaries = supportsReasoningSummaries
        self.serviceTier = serviceTier
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.usesResponsesLite = usesResponsesLite
        self.inputModalities = inputModalities
        self.verbosity = verbosity
        self.availableModelOptions = availableModelOptions
        self.webSearch = webSearch
        self.maxToolIterations = maxToolIterations
    }
}

public enum CodexInput: Sendable, Equatable {
    case text(String)
    case imageURL(URL)
    case imageData(Data, mimeType: String)

    var responsesContentPart: [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "input_text", "text": text]
        case .imageURL(let url):
            return ["type": "input_image", "image_url": url.absoluteString]
        case .imageData(let data, let mimeType):
            let encoded = data.base64EncodedString()
            return ["type": "input_image", "image_url": "data:\(mimeType);base64,\(encoded)"]
        }
    }
}
