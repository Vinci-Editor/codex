import Foundation

public struct CodexSubagentOptions: Sendable, Equatable {
    public let isEnabled: Bool
    public let maxOpenAgents: Int
    public let defaultWaitTimeoutMilliseconds: Int
    public let minWaitTimeoutMilliseconds: Int
    public let maxWaitTimeoutMilliseconds: Int

    public init(
        isEnabled: Bool,
        maxOpenAgents: Int = 4,
        defaultWaitTimeoutMilliseconds: Int = 30_000,
        minWaitTimeoutMilliseconds: Int = 10_000,
        maxWaitTimeoutMilliseconds: Int = 3_600_000
    ) {
        self.isEnabled = isEnabled
        self.maxOpenAgents = max(1, maxOpenAgents)
        self.defaultWaitTimeoutMilliseconds = max(1, defaultWaitTimeoutMilliseconds)
        self.minWaitTimeoutMilliseconds = max(1, minWaitTimeoutMilliseconds)
        self.maxWaitTimeoutMilliseconds = max(self.minWaitTimeoutMilliseconds, maxWaitTimeoutMilliseconds)
    }

    public static let disabled = CodexSubagentOptions(isEnabled: false)
    public static let enabled = CodexSubagentOptions(isEnabled: true)
}
