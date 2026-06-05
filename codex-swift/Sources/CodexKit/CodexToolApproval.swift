import Foundation

public enum CodexToolApprovalDecision: Sendable, Equatable {
    case approve
    case approveForSession(prefixRule: [String])
    case deny(String)
}

public enum CodexToolApprovalRequirement: Sendable, Equatable {
    case none
    case required(reason: String)
}

public enum CodexToolSandboxPermissions: String, Sendable, Equatable, Codable {
    case useDefault = "use_default"
    case requireEscalated = "require_escalated"
}

public struct CodexToolApprovalRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let call: CodexToolCall
    public let reason: String
    public let summary: String
    public let command: String?
    public let workdir: String?
    public let sandboxPermissions: CodexToolSandboxPermissions
    public let justification: String?
    public let suggestedPrefixRule: [String]

    public init(
        id: UUID = UUID(),
        call: CodexToolCall,
        reason: String,
        summary: String,
        command: String? = nil,
        workdir: String? = nil,
        sandboxPermissions: CodexToolSandboxPermissions = .useDefault,
        justification: String? = nil,
        suggestedPrefixRule: [String] = []
    ) {
        self.id = id
        self.call = call
        self.reason = reason
        self.summary = summary
        self.command = command
        self.workdir = workdir
        self.sandboxPermissions = sandboxPermissions
        self.justification = justification
        self.suggestedPrefixRule = suggestedPrefixRule
    }
}

public typealias CodexToolApprovalHandler = @MainActor @Sendable (CodexToolApprovalRequest) async -> CodexToolApprovalDecision
