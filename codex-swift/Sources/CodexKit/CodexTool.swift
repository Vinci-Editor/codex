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

    public init(output: String, success: Bool = true) {
        self.output = output
        self.success = success
    }
}

public protocol CodexTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: any Sendable] { get }
    var supportsParallelCalls: Bool { get }

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
