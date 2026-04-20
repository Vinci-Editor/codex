import Foundation

public struct CodexToolCall: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
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
