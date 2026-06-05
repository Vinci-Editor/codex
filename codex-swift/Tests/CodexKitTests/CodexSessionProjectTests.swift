//
//  CodexSessionProjectTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func sessionConfigurationPreservesAutomaticCompactionOptionsWhenAddingApprovalHandler() {
    let configuration = CodexSessionConfiguration(
        provider: .openAI,
        compactionOptions: .automatic(triggerApproxTokens: 123_456)
    )
    let wrapped = configuration.withToolApprovalHandler { _ in .approve }

    #expect(wrapped.compactionOptions.automaticTriggerApproxTokens == 123_456)
}


@Test
func sessionConfigurationAppendsAdditionalTools() {
    let store = InMemoryGoalStore(threadID: "thread-1")
    let configuration = CodexSessionConfiguration(provider: .openAI)
        .withAdditionalTools(CodexGoalTool.all(store: store))

    #expect(configuration.tools.map(\.name) == ["get_goal", "create_goal", "update_goal"])
}


@Test
func sessionRequestInputPrependsContextualUserInstructionsWithoutMutatingHistory() {
    let history = [
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "User task"]],
        ]
    ]
    let input = CodexSession.requestInputHistory(
        contextualUserInstructions: "# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>\nProject rules\n</INSTRUCTIONS>",
        history: history
    )

    #expect(input.count == 2)
    #expect(input[0]["role"] as? String == "user")
    #expect(((input[0]["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("Project rules") == true)
    #expect(input[1]["role"] as? String == "user")
    #expect(history.count == 1)
}


@Test
func projectInstructionsLoadRootToCurrentDirectoryAndPreferOverride() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let nested = root.appending(path: "Sources/App", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "root instructions".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try "shadowed".write(to: nested.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try "nested override".write(to: nested.appending(path: "AGENTS.override.md"), atomically: true, encoding: .utf8)

    let loadedInstructions = try CodexProjectInstructions.load(
        from: root,
        currentDirectoryURL: nested
    )
    let instructions = try #require(loadedInstructions)

    #expect(instructions.sources.map(\.lastPathComponent) == ["AGENTS.md", "AGENTS.override.md"])
    #expect(instructions.text.hasPrefix("# AGENTS.md instructions for \(nested.path(percentEncoded: false))"))
    #expect(instructions.text.contains("root instructions"))
    #expect(instructions.text.contains("nested override"))
    #expect(!instructions.text.contains("shadowed"))
}


@Test
func projectInstructionsRespectByteLimitAcrossSources() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "123456".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try "abcdef".write(to: nested.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

    let loadedInstructions = try CodexProjectInstructions.load(
        from: root,
        currentDirectoryURL: nested,
        maxBytes: 8
    )
    let instructions = try #require(loadedInstructions)

    #expect(instructions.text.contains("123456"))
    #expect(instructions.text.contains("ab"))
    #expect(!instructions.text.contains("abc"))
}


@Test
func projectSkillsLoadRootToCurrentDirectorySkillRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let nested = root.appending(path: "Sources/App", directoryHint: .isDirectory)
    let alpha = root.appending(path: ".codex/skills/alpha", directoryHint: .isDirectory)
    let beta = nested.appending(path: ".agents/skills/beta", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    try """
    ---
    name: alpha-skill
    description: Root skill
    ---

    # Alpha
    """.write(to: alpha.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: "beta-skill"
    description: "Long beta description"
    metadata:
      short-description: "Short beta"
    ---

    # Beta
    """.write(to: beta.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

    let loadedSkills = try CodexProjectSkills.load(from: root, currentDirectoryURL: nested)
    let skills = try #require(loadedSkills)

    #expect(skills.skills.map(\.name) == ["alpha-skill", "beta-skill"])
    #expect(skills.skills[1].shortDescription == "Short beta")
    #expect(skills.text.contains("<skills_instructions>"))
    #expect(skills.text.contains("alpha-skill: Root skill"))
    #expect(skills.text.contains("beta-skill: Short beta"))
    #expect(skills.text.contains("After deciding to use a skill, open its `SKILL.md`"))
}


@Test
func webSearchOptionsBuildHostedToolDefinition() throws {
    let webSearch = CodexWebSearchOptions(
        mode: .live,
        searchContextSize: .high,
        allowedDomains: ["developer.apple.com"]
    )
    let body = try CodexMobileCoreBridge.buildResponsesRequest([
        "model": "gpt-5.4",
        "input": [],
        "tools": [webSearch.responsesToolDefinition],
        "stream": true,
        "store": false,
    ])
    let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let tool = (value?["tools"] as? [[String: Any]])?.first
    let filters = tool?["filters"] as? [String: Any]

    #expect(tool?["type"] as? String == "web_search")
    #expect(tool?["external_web_access"] as? Bool == true)
    #expect(tool?["search_context_size"] as? String == "high")
    #expect(filters?["allowed_domains"] as? [String] == ["developer.apple.com"])
}


@Test
func codexSessionDecodesWebSearchEvents() throws {
    let event = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "ws_1",
            "type": "web_search_call",
            "status": "completed",
            "action": [
                "type": "find_in_page",
                "url": "https://developer.apple.com/documentation/swiftui",
                "pattern": "NavigationSplitView",
            ],
        ],
    ])

    guard case .webSearch(let call) = event else {
        Issue.record("Expected webSearch event, got \(event)")
        return
    }
    #expect(call.id == "ws_1")
    #expect(call.isCompleted)
    #expect(call.actionType == "find_in_page")
    #expect(call.detail == "'NavigationSplitView' in https://developer.apple.com/documentation/swiftui")
}


@Test
func codexSessionBuildsCompactedHistoryFromUserMessagesAndSummary() throws {
    let history: [[String: Any]] = [
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "Build a SwiftUI chat UI."]],
        ],
        [
            "type": "message",
            "role": "assistant",
            "content": [["type": "output_text", "text": "Implemented the first pass."]],
        ],
        [
            "type": "function_call_output",
            "call_id": "call-1",
            "output": "tool output",
        ],
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "\(CodexSession.compactionSummaryPrefix)\nOld summary"]],
        ],
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "Add context compaction."]],
        ],
    ]

    let compacted = CodexSession.compactedHistory(summary: "Compaction summary.", from: history)
    let texts = compacted.compactMap { item -> String? in
        guard let content = item["content"] as? [Any],
              let first = content.first as? [String: Any] else {
            return nil
        }
        return first["text"] as? String
    }

    #expect(compacted.count == 3)
    #expect(texts[0] == "Build a SwiftUI chat UI.")
    #expect(texts[1] == "Add context compaction.")
    #expect(texts[2] == "\(CodexSession.compactionSummaryPrefix)\nCompaction summary.")
}


@Test
func codexSessionEstimatesHistoryTokensForAutomaticCompaction() {
    let shortHistory: [[String: Any]] = [
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "short"]],
        ],
    ]
    let longHistory: [[String: Any]] = [
        [
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": String(repeating: "x", count: 8_000)]],
        ],
    ]

    #expect(CodexSession.approximateHistoryTokenCount(longHistory) > CodexSession.approximateHistoryTokenCount(shortHistory))
    #expect(CodexSession.approximateHistoryTokenCount(longHistory) > 1_000)
}
