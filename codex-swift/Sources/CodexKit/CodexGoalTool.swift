import Foundation

/// Codex app-server thread goal status values.
public enum CodexGoalStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete
}

/// Host-owned state for a Codex thread goal.
public struct CodexGoal: Codable, Sendable, Equatable, Hashable {
    public let threadID: String
    public let objective: String
    public let status: CodexGoalStatus
    public let tokenBudget: Int?
    public let tokensUsed: Int
    public let timeUsedSeconds: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        threadID: String,
        objective: String,
        status: CodexGoalStatus = .active,
        tokenBudget: Int? = nil,
        tokensUsed: Int = 0,
        timeUsedSeconds: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = max(tokensUsed, 0)
        self.timeUsedSeconds = max(timeUsedSeconds, 0)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var remainingTokens: Int? {
        tokenBudget.map { max($0 - tokensUsed, 0) }
    }

    public func withProgress(tokens: Int, elapsedSeconds: Int, now: Date = Date()) -> CodexGoal {
        let nextTokensUsed = max(tokensUsed + max(tokens, 0), 0)
        let nextStatus: CodexGoalStatus
        if status == .active,
           let tokenBudget,
           nextTokensUsed >= tokenBudget {
            nextStatus = .budgetLimited
        } else {
            nextStatus = status
        }
        return CodexGoal(
            threadID: threadID,
            objective: objective,
            status: nextStatus,
            tokenBudget: tokenBudget,
            tokensUsed: nextTokensUsed,
            timeUsedSeconds: max(timeUsedSeconds + max(elapsedSeconds, 0), 0),
            createdAt: createdAt,
            updatedAt: now
        )
    }

    public func withStatus(_ status: CodexGoalStatus, now: Date = Date()) -> CodexGoal {
        CodexGoal(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget,
            tokensUsed: tokensUsed,
            timeUsedSeconds: timeUsedSeconds,
            createdAt: createdAt,
            updatedAt: now
        )
    }
}

/// Errors returned by a host-owned goal store.
public enum CodexGoalStoreError: Error, Sendable, Equatable {
    case goalAlreadyExists
    case goalMissing
    case invalidRequest(String)
}

/// Stores the current goal for one Codex thread.
///
/// Implementations should persist the goal alongside the host app's conversation
/// state and account token or elapsed-time usage from completed turns.
public protocol CodexGoalStore: Sendable {
    /// Returns the current goal, or nil when no goal has been created.
    func currentGoal() async throws -> CodexGoal?

    /// Creates a new active goal. Throw `goalAlreadyExists` if a goal is already defined.
    func createGoal(objective: String, tokenBudget: Int?) async throws -> CodexGoal

    /// Updates an existing goal status. Tool callers may only request `complete` or `blocked`.
    func updateGoal(status: CodexGoalStatus) async throws -> CodexGoal
}

/// Codex-compatible `get_goal`, `create_goal`, and `update_goal` tools.
public struct CodexGoalTool: CodexTool {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case get
        case create
        case update
    }

    private let kind: Kind
    private let store: any CodexGoalStore

    public init(kind: Kind, store: any CodexGoalStore) {
        self.kind = kind
        self.store = store
    }

    public static func all(store: any CodexGoalStore) -> [any CodexTool] {
        [
            CodexGoalTool(kind: .get, store: store),
            CodexGoalTool(kind: .create, store: store),
            CodexGoalTool(kind: .update, store: store),
        ]
    }

    public var name: String {
        switch kind {
        case .get:
            return "get_goal"
        case .create:
            return "create_goal"
        case .update:
            return "update_goal"
        }
    }

    public var description: String {
        switch kind {
        case .get:
            return "Get the current goal for this thread, including status, budgets, token and elapsed-time usage, and remaining token budget."
        case .create:
            return """
            Create a goal only when explicitly requested by the user or system/developer instructions; do not infer goals from ordinary tasks.
            Set token_budget only when an explicit token budget is requested. Fails if a goal exists; use update_goal only for status.
            """
        case .update:
            return """
            Update the existing goal.
            Use this tool only to mark the goal achieved or blocked.
            Set status to `complete` only when the objective has actually been achieved and no required work remains.
            Set status to `blocked` only when the same blocking condition has repeated for at least three consecutive goal turns, counting the original/user-triggered turn and any automatic continuations, and the agent cannot make meaningful progress without user input or an external-state change.
            If the user resumes a goal that was previously marked `blocked`, treat the resumed run as a fresh blocked audit.
            Once the blocked threshold is satisfied, do not keep reporting that you are still blocked while leaving the goal active; set status to `blocked`.
            Do not use `blocked` merely because the work is hard, slow, uncertain, incomplete, or would benefit from clarification.
            Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work.
            You cannot use this tool to pause, resume, budget-limit, or usage-limit a goal; those status changes are controlled by the user or system.
            When marking a budgeted goal achieved with status `complete`, report the final token usage from the tool result to the user.
            """
        }
    }

    public var inputSchema: [String: any Sendable] {
        switch kind {
        case .get:
            return CodexJSONSchema.object(properties: [:]).inputSchema
        case .create:
            return CodexJSONSchema.object(
                properties: [
                    "objective": .string(description: "Required. The concrete objective to start pursuing. This starts a new active goal only when no goal is currently defined; if a goal already exists, this tool fails."),
                    "token_budget": .integer(description: "Optional positive token budget for the new active goal."),
                ],
                required: ["objective"]
            ).inputSchema
        case .update:
            return CodexJSONSchema.object(
                properties: [
                    "status": .stringEnum(
                        ["complete", "blocked"],
                        description: "Required. Set to complete only when the objective is achieved and no required work remains. Set to blocked only after the same blocking condition has repeated for at least three consecutive goal turns and the agent is at an impasse."
                    ),
                ],
                required: ["status"]
            ).inputSchema
        }
    }

    public func execute(call: CodexToolCall, context: CodexToolContext) async throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        do {
            switch kind {
            case .get:
                let goal = try await store.currentGoal()
                return try goalResult(goal: goal, includeCompletionBudgetReport: false)
            case .create:
                let objective = (arguments["objective"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try Self.validateObjective(objective)
                let goal = try await store.createGoal(
                    objective: objective,
                    tokenBudget: try Self.tokenBudget(from: arguments["token_budget"])
                )
                return try goalResult(goal: goal, includeCompletionBudgetReport: false)
            case .update:
                let status = try Self.updateStatus(from: arguments["status"])
                let goal = try await store.updateGoal(status: status)
                return try goalResult(goal: goal, includeCompletionBudgetReport: status == .complete)
            }
        } catch let error as CodexGoalStoreError {
            return CodexToolResult(output: Self.errorMessage(error), success: false)
        }
    }

    private func goalResult(
        goal: CodexGoal?,
        includeCompletionBudgetReport: Bool
    ) throws -> CodexToolResult {
        let remainingTokens: Any
        if let goal, let remaining = goal.remainingTokens {
            remainingTokens = remaining
        } else {
            remainingTokens = NSNull()
        }
        let goalPayload: Any = goal.map { Self.payload($0) as Any } ?? NSNull()

        var payload: [String: Any] = [
            "goal": goalPayload,
            "remainingTokens": remainingTokens,
            "completionBudgetReport": NSNull(),
        ]
        if includeCompletionBudgetReport,
           let goal,
           goal.status == .complete,
           goal.tokenBudget != nil || goal.timeUsedSeconds > 0 {
            payload["completionBudgetReport"] = "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.tokenBudget` is present, include token usage from `goal.tokensUsed` and `goal.tokenBudget`. If `goal.timeUsedSeconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language."
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return CodexToolResult(output: String(decoding: data, as: UTF8.self))
    }

    private static func payload(_ goal: CodexGoal) -> [String: Any] {
        let tokenBudget: Any = goal.tokenBudget.map { $0 as Any } ?? NSNull()
        return [
            "threadId": goal.threadID,
            "objective": goal.objective,
            "status": goal.status.rawValue,
            "tokenBudget": tokenBudget,
            "tokensUsed": goal.tokensUsed,
            "timeUsedSeconds": goal.timeUsedSeconds,
            "createdAt": Int(goal.createdAt.timeIntervalSince1970),
            "updatedAt": Int(goal.updatedAt.timeIntervalSince1970),
        ]
    }

    private static func decodeArguments(_ arguments: String) throws -> [String: Any] {
        guard !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let value = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        return value as? [String: Any] ?? [:]
    }

    private static func validateObjective(_ objective: String) throws {
        guard !objective.isEmpty else {
            throw CodexGoalStoreError.invalidRequest("goal objective must not be empty")
        }
        guard objective.count <= 4_000 else {
            throw CodexGoalStoreError.invalidRequest("goal objective must be at most 4000 characters")
        }
    }

    private static func tokenBudget(from value: Any?) throws -> Int? {
        guard let value else {
            return nil
        }
        let budget: Int?
        switch value {
        case let value as Int:
            budget = value
        case let value as Double:
            guard value.rounded(.towardZero) == value else {
                throw CodexGoalStoreError.invalidRequest("goal budgets must be positive when provided")
            }
            budget = Int(value)
        case let value as String:
            budget = Int(value)
        default:
            budget = nil
        }
        guard let budget, budget > 0 else {
            throw CodexGoalStoreError.invalidRequest("goal budgets must be positive when provided")
        }
        return budget
    }

    private static func updateStatus(from value: Any?) throws -> CodexGoalStatus {
        guard let raw = value as? String,
              let status = CodexGoalStatus(rawValue: raw),
              status == .complete || status == .blocked else {
            throw CodexGoalStoreError.invalidRequest("update_goal can only mark the existing goal complete or blocked; pause, resume, budget-limited, and usage-limited status changes are controlled by the user or system")
        }
        return status
    }

    private static func errorMessage(_ error: CodexGoalStoreError) -> String {
        switch error {
        case .goalAlreadyExists:
            return "cannot create a new goal because this thread already has a goal; use update_goal only when the existing goal is complete"
        case .goalMissing:
            return "cannot update goal because this thread has no goal"
        case .invalidRequest(let message):
            return message
        }
    }
}
