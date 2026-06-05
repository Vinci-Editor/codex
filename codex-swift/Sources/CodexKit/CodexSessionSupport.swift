//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

struct TurnStreamResult {
    let assistantTextItems: [AssistantTextItem]
    let toolCalls: [CodexToolCall]
}

struct AssistantTextItem {
    let itemID: String
    let text: String
}

struct SubagentRecord {
    let id: String
    let taskName: String
    let path: String
    let agentRole: String?
    let agentNickname: String?
    let session: CodexSession
    var status: SubagentStatus
    var task: Task<Void, Never>?
    var finalAnswer: String?
    var errorMessage: String?
    var queuedMessages: [String] = []
    var queuedFollowups: [String] = []
    var turnOptions: CodexTurnOptions?
    var statusBeforeClose: SubagentStatus?
    let createdOrder: Int
}

enum SubagentStatus: String {
    case running
    case completed
    case failed
    case closed

    var isFinal: Bool {
        self == .completed || self == .failed
    }

    var isClosed: Bool {
        self == .closed
    }
}

actor CodexSubagentRegistry {
    var sequence = 0
    var openAgentIDs: Set<String> = []
    var statusByID: [String: CodexSubagentStatus] = [:]
    var orderByID: [String: Int] = [:]
    var ownerByID: [String: WeakCodexSessionReference] = [:]

    func reserveAgent(maxOpenAgents: Int) -> String? {
        guard openAgentIDs.count < maxOpenAgents else {
            return nil
        }
        sequence += 1
        let id = "agent-\(sequence)"
        openAgentIDs.insert(id)
        orderByID[id] = sequence
        return id
    }

    func reserveAgent(id: String, maxOpenAgents: Int) -> Bool {
        if openAgentIDs.contains(id) {
            return true
        }
        guard openAgentIDs.count < maxOpenAgents else {
            return false
        }
        openAgentIDs.insert(id)
        if orderByID[id] == nil {
            sequence += 1
            orderByID[id] = sequence
        }
        return true
    }

    func update(_ status: CodexSubagentStatus, owner: CodexSession? = nil) {
        statusByID[status.agentID] = status
        if let owner {
            ownerByID[status.agentID] = WeakCodexSessionReference(owner)
        }
        if orderByID[status.agentID] == nil {
            sequence += 1
            orderByID[status.agentID] = sequence
        }
        if status.status == SubagentStatus.closed.rawValue {
            openAgentIDs.remove(status.agentID)
        } else {
            openAgentIDs.insert(status.agentID)
        }
    }

    func owner(for rawTarget: String, relativeTo agentPath: String) -> CodexSession? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return nil
        }
        if let owner = ownerByID[target]?.session {
            return owner
        }

        let path = target.hasPrefix("/")
            ? target
            : (agentPath == "/" ? "/\(target)" : "\(agentPath)/\(target)")
        guard let status = statusByID.values.first(where: { $0.path == path }) else {
            return nil
        }
        return ownerByID[status.agentID]?.session
    }

    func statusSnapshot() -> [CodexSubagentStatus] {
        statusByID.values
            .filter { $0.status != SubagentStatus.closed.rawValue }
            .sorted { lhs, rhs in
                let lhsOrder = orderByID[lhs.agentID] ?? Int.max
                let rhsOrder = orderByID[rhs.agentID] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.path < rhs.path
            }
    }
}

final class WeakCodexSessionReference: @unchecked Sendable {
    weak var session: CodexSession?

    init(_ session: CodexSession) {
        self.session = session
    }
}

final class SubagentWaitRace: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Bool, Never>?
    var waiter: Task<Void, Never>?
    var sleeper: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func setTasks(waiter: Task<Void, Never>, sleeper: Task<Void, Never>) {
        var shouldCancel = false
        lock.lock()
        if continuation == nil {
            shouldCancel = true
        } else {
            self.waiter = waiter
            self.sleeper = sleeper
        }
        lock.unlock()

        if shouldCancel {
            waiter.cancel()
            sleeper.cancel()
        }
    }

    func finish(_ completed: Bool) {
        let continuationToResume: CheckedContinuation<Bool, Never>?
        let waiterToCancel: Task<Void, Never>?
        let sleeperToCancel: Task<Void, Never>?
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        waiterToCancel = waiter
        sleeperToCancel = sleeper
        waiter = nil
        sleeper = nil
        lock.unlock()

        waiterToCancel?.cancel()
        sleeperToCancel?.cancel()
        continuationToResume?.resume(returning: completed)
    }
}

public enum CodexSessionError: Error, Equatable {
    case missingAuthentication
    case httpStatus(Int, String)
    case unknownTool(String)
    case workspacePathError(String)
    case compactionUnavailable(String)
    case toolLoopLimitExceeded
}
