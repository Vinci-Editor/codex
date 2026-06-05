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
    public let serviceTier: String?
    public let toolChoice: String?
    public let parallelToolCalls: Bool?
    public let inputModalities: [String]?
    public let webSearch: CodexWebSearchOptions?

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool? = nil,
        inputModalities: [String]? = nil,
        webSearch: CodexWebSearchOptions? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.inputModalities = inputModalities
        self.webSearch = webSearch
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
