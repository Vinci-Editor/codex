import Foundation

public struct CodexToolCall: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case function
        case custom
    }

    public let itemID: String?
    public let callID: String
    public let name: String
    public let arguments: String
    public let kind: Kind

    public init(itemID: String? = nil, callID: String, name: String, arguments: String, kind: Kind = .function) {
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.kind = kind
    }
}

public struct CodexToolResult: Sendable, Equatable {
    public let output: String
    public let success: Bool
    public let responseOutput: CodexToolResponseOutput?
    public let planUpdate: CodexPlanUpdate?

    public init(
        output: String,
        success: Bool = true,
        responseOutput: CodexToolResponseOutput? = nil,
        planUpdate: CodexPlanUpdate? = nil
    ) {
        self.output = output
        self.success = success
        self.responseOutput = responseOutput
        self.planUpdate = planUpdate
    }
}

public enum CodexToolResponseOutput: Sendable, Equatable {
    case text(String)
    case inputImage(imageURL: String, detail: String?)

    var jsonValue: Any {
        switch self {
        case .text(let text):
            return text
        case .inputImage(let imageURL, let detail):
            var item: [String: Any] = [
                "type": "input_image",
                "image_url": imageURL,
            ]
            if let detail {
                item["detail"] = detail
            }
            return [item]
        }
    }
}

public struct CodexPlanUpdate: Codable, Sendable, Equatable, Hashable {
    public let explanation: String?
    public let items: [CodexPlanItem]

    public init(explanation: String? = nil, items: [CodexPlanItem]) {
        self.explanation = explanation
        self.items = items
    }
}

public struct CodexPlanItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Equatable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id: UUID
    public let step: String
    public let status: Status

    public init(id: UUID = UUID(), step: String, status: Status) {
        self.id = id
        self.step = step
        self.status = status
    }
}

public protocol CodexTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: any Sendable] { get }
    var supportsParallelCalls: Bool { get }

    func approvalRequirement(for call: CodexToolCall) -> CodexToolApprovalRequirement
    func execute(call: CodexToolCall, context: CodexToolContext) async throws -> CodexToolResult
}

public struct CodexToolProgress: Sendable, Equatable {
    public let status: String?
    public let outputDelta: String?

    public init(status: String? = nil, outputDelta: String? = nil) {
        self.status = status
        self.outputDelta = outputDelta
    }

    public static func status(_ value: String) -> CodexToolProgress {
        CodexToolProgress(status: value)
    }

    public static func outputDelta(_ value: String) -> CodexToolProgress {
        CodexToolProgress(outputDelta: value)
    }
}

public typealias CodexToolProgressHandler = @Sendable (CodexToolProgress) -> Void

public protocol CodexStreamingTool: CodexTool {
    func execute(
        call: CodexToolCall,
        context: CodexToolContext,
        progress: CodexToolProgressHandler?
    ) async throws -> CodexToolResult
}

public extension CodexTool {
    var supportsParallelCalls: Bool { true }

    func approvalRequirement(for call: CodexToolCall) -> CodexToolApprovalRequirement {
        .none
    }

    func responsesToolDefinition() -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "strict": false,
            "parameters": inputSchema,
        ]
    }
}

public struct CodexToolContext: Sendable {
    public let workspace: CodexWorkspace?

    public init(workspace: CodexWorkspace?) {
        self.workspace = workspace
    }
}
