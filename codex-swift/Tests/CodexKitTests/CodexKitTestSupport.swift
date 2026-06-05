//
//  CodexKitTestSupport.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

func jwt(payload: [String: Any]) throws -> String {
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadPart = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payloadPart).signature"
}

func toolOutputBody(_ data: Data) throws -> String {
    let item = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return item?["output"] as? String ?? ""
}

func jsonObject(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
}

func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

actor InMemoryGoalStore: CodexGoalStore {
    private let threadID: String
    private var goal: CodexGoal?

    init(threadID: String) {
        self.threadID = threadID
    }

    func currentGoal() async throws -> CodexGoal? {
        goal
    }

    func createGoal(objective: String, tokenBudget: Int?) async throws -> CodexGoal {
        guard goal == nil else {
            throw CodexGoalStoreError.goalAlreadyExists
        }
        let created = CodexGoal(threadID: threadID, objective: objective, tokenBudget: tokenBudget)
        goal = created
        return created
    }

    func updateGoal(status: CodexGoalStatus) async throws -> CodexGoal {
        guard let current = goal else {
            throw CodexGoalStoreError.goalMissing
        }
        let updated = current.withStatus(status)
        goal = updated
        return updated
    }

    func account(tokens: Int, elapsedSeconds: Int) {
        goal = goal?.withProgress(tokens: tokens, elapsedSeconds: elapsedSeconds)
    }
}
