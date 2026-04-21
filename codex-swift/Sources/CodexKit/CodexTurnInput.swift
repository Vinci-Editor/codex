import Foundation

public struct CodexTurnOptions: Sendable, Equatable {
    public let model: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let toolChoice: String?
    public let parallelToolCalls: Bool?

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
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
