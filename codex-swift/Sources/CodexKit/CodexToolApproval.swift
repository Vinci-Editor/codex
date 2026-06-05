import Foundation

public enum CodexToolApprovalDecision: Sendable, Equatable {
    case approve
    case deny(String)
}

public enum CodexToolApprovalRequirement: Sendable, Equatable {
    case none
    case required(reason: String)
}

public struct CodexToolApprovalRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let call: CodexToolCall
    public let reason: String
    public let summary: String

    public init(
        id: UUID = UUID(),
        call: CodexToolCall,
        reason: String,
        summary: String
    ) {
        self.id = id
        self.call = call
        self.reason = reason
        self.summary = summary
    }
}

public typealias CodexToolApprovalHandler = @MainActor @Sendable (CodexToolApprovalRequest) async -> CodexToolApprovalDecision
