import Foundation

public struct CodexSubagentRole: Sendable, Equatable, Hashable {
    public let name: String
    public let description: String
    public let nicknameCandidates: [String]
    public let additionalInstructions: String?
    public let model: String?
    public let reasoningEffort: String?
    public let serviceTier: String?

    public init(
        name: String,
        description: String,
        nicknameCandidates: [String] = [],
        additionalInstructions: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nicknameCandidates = Self.normalizedNicknameCandidates(nicknameCandidates)
        self.additionalInstructions = Self.trimmedNonEmpty(additionalInstructions)
        self.model = Self.trimmedNonEmpty(model)
        self.reasoningEffort = Self.trimmedNonEmpty(reasoningEffort)
        self.serviceTier = Self.trimmedNonEmpty(serviceTier)
    }

    public static let `default` = CodexSubagentRole(
        name: "default",
        description: "Default agent."
    )

    public static let explorer = CodexSubagentRole(
        name: "explorer",
        description: "Use for specific, well-scoped codebase questions that can be answered independently.",
        additionalInstructions: """
        You are an explorer subagent. Answer the specific delegated question with concise, evidence-backed findings. Avoid broad implementation work unless your parent explicitly asks for it.
        """
    )

    public static let worker = CodexSubagentRole(
        name: "worker",
        description: "Use for bounded implementation, bug-fixing, and production work with clear file ownership.",
        additionalInstructions: """
        You are a worker subagent. Own the specific implementation scope assigned by your parent, avoid overlapping unrelated files, and preserve changes made by other agents or users. Report the concrete files changed, validation performed, and any remaining integration risks.
        """
    )

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedNicknameCandidates(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }
}

public struct CodexSubagentOptions: Sendable, Equatable {
    public let isEnabled: Bool
    public let maxOpenAgents: Int
    public let maxDepth: Int?
    public let roles: [CodexSubagentRole]
    public let defaultWaitTimeoutMilliseconds: Int
    public let minWaitTimeoutMilliseconds: Int
    public let maxWaitTimeoutMilliseconds: Int

    public init(
        isEnabled: Bool,
        maxOpenAgents: Int = 4,
        maxDepth: Int? = nil,
        roles: [CodexSubagentRole] = [.default, .explorer, .worker],
        defaultWaitTimeoutMilliseconds: Int = 30_000,
        minWaitTimeoutMilliseconds: Int = 10_000,
        maxWaitTimeoutMilliseconds: Int = 3_600_000
    ) {
        self.isEnabled = isEnabled
        self.maxOpenAgents = max(1, maxOpenAgents)
        self.maxDepth = maxDepth.map { max(1, $0) }
        self.roles = Self.normalizedRoles(roles)
        self.defaultWaitTimeoutMilliseconds = max(1, defaultWaitTimeoutMilliseconds)
        self.minWaitTimeoutMilliseconds = max(1, minWaitTimeoutMilliseconds)
        self.maxWaitTimeoutMilliseconds = max(self.minWaitTimeoutMilliseconds, maxWaitTimeoutMilliseconds)
    }

    public static let disabled = CodexSubagentOptions(isEnabled: false)
    public static let enabled = CodexSubagentOptions(isEnabled: true)

    public static func isValidRoleName(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        return value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func normalizedRoles(_ roles: [CodexSubagentRole]) -> [CodexSubagentRole] {
        let candidates = roles.contains(where: { $0.name == CodexSubagentRole.default.name })
            ? roles
            : [.default] + roles
        var seen: Set<String> = []
        return candidates.compactMap { role in
            guard isValidRoleName(role.name), seen.insert(role.name).inserted else {
                return nil
            }
            return role
        }
    }
}
