//
//  CodexGoalToolTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func goalToolsCreateReadAndCompleteGoal() async throws {
    let store = InMemoryGoalStore(threadID: "thread-1")
    let create = CodexGoalTool(kind: .create, store: store)
    let get = CodexGoalTool(kind: .get, store: store)
    let update = CodexGoalTool(kind: .update, store: store)

    let createResult = try await create.execute(
        call: CodexToolCall(
            callID: "call-create",
            name: "create_goal",
            arguments: try jsonString(["objective": "Ship the Codex integration", "token_budget": 1_000])
        ),
        context: CodexToolContext(workspace: nil)
    )
    let createPayload = try jsonObject(createResult.output)

    #expect((createPayload["goal"] as? [String: Any])?["objective"] as? String == "Ship the Codex integration")
    #expect((createPayload["goal"] as? [String: Any])?["status"] as? String == "active")
    #expect(createPayload["remainingTokens"] as? Int == 1_000)

    await store.account(tokens: 250, elapsedSeconds: 12)
    let getResult = try await get.execute(
        call: CodexToolCall(callID: "call-get", name: "get_goal", arguments: "{}"),
        context: CodexToolContext(workspace: nil)
    )
    let getPayload = try jsonObject(getResult.output)
    #expect((getPayload["goal"] as? [String: Any])?["tokensUsed"] as? Int == 250)
    #expect(getPayload["remainingTokens"] as? Int == 750)

    let updateResult = try await update.execute(
        call: CodexToolCall(callID: "call-update", name: "update_goal", arguments: #"{"status":"complete"}"#),
        context: CodexToolContext(workspace: nil)
    )
    let updatePayload = try jsonObject(updateResult.output)
    #expect((updatePayload["goal"] as? [String: Any])?["status"] as? String == "complete")
    #expect((updatePayload["completionBudgetReport"] as? String)?.contains("Goal achieved") == true)
}


@Test
func goalToolsRejectDuplicateCreateAndUnsupportedStatus() async throws {
    let store = InMemoryGoalStore(threadID: "thread-1")
    let create = CodexGoalTool(kind: .create, store: store)
    let update = CodexGoalTool(kind: .update, store: store)
    let context = CodexToolContext(workspace: nil)

    _ = try await create.execute(
        call: CodexToolCall(callID: "call-create", name: "create_goal", arguments: try jsonString(["objective": "Goal"])),
        context: context
    )
    let duplicate = try await create.execute(
        call: CodexToolCall(callID: "call-duplicate", name: "create_goal", arguments: try jsonString(["objective": "Other"])),
        context: context
    )
    let unsupportedStatus = try await update.execute(
        call: CodexToolCall(callID: "call-update", name: "update_goal", arguments: #"{"status":"active"}"#),
        context: context
    )

    #expect(!duplicate.success)
    #expect(duplicate.output.contains("already has a goal"))
    #expect(!unsupportedStatus.success)
    #expect(unsupportedStatus.output.contains("complete or blocked"))
}
