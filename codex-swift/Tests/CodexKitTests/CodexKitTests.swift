import Foundation
import Testing
@testable import CodexKit
import CodexMobileCoreBridge

@Test
func providerDefaultsExposeOpenAIAndLocalProviders() {
    let providers = CodexProvider.defaults()

    #expect(providers.map(\.id) == ["openai", "lmstudio", "ollama"])
    #expect(providers[0].baseURL.absoluteString == "https://chatgpt.com/backend-api/codex")
    #expect(providers[1].baseURL.absoluteString == "http://127.0.0.1:1234/v1")
}

@Test
func modelCatalogDecodesCodexBackendModels() throws {
    let data = Data("""
    {
      "models": [
        {
          "slug": "hidden",
          "display_name": "Hidden",
          "description": "Hidden model",
          "default_reasoning_level": "medium",
          "supported_reasoning_levels": [],
          "visibility": "hide",
          "supported_in_api": true,
          "priority": 0,
          "input_modalities": ["text"]
        },
        {
          "slug": "gpt-5.4",
          "display_name": "GPT-5.4",
          "description": "Latest",
          "default_reasoning_level": "medium",
          "supported_reasoning_levels": [
            {"effort": "low", "description": "Low"},
            {"effort": "xhigh", "description": "Extra high"}
          ],
          "visibility": "list",
          "supported_in_api": true,
          "use_responses_lite": true,
          "priority": 2,
          "input_modalities": ["text", "image"]
        }
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .openAI)

    #expect(models.map(\.id) == ["gpt-5.4"])
    #expect(models[0].isDefault)
    #expect(models[0].defaultReasoningEffort == "medium")
    #expect(models[0].supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "xhigh"])
    #expect(models[0].usesResponsesLite)
    #expect(models[0].inputModalities == ["text", "image"])
}

@Test
func modelCatalogDecodesAppServerResponsesLiteModels() throws {
    let data = Data("""
    {
      "data": [
        {
          "id": "gpt-5.4",
          "displayName": "GPT-5.4",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "medium", "description": "Medium"}
          ],
          "usesResponsesLite": true,
          "inputModalities": ["text", "image"]
        }
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .openAI)

    #expect(models.map(\.id) == ["gpt-5.4"])
    #expect(models[0].usesResponsesLite)
    #expect(models[0].inputModalities == ["text", "image"])
}

@Test
func modelOptionDecodesOlderPersistedValuesWithoutResponsesLiteFlag() throws {
    let data = Data("""
    {
      "id": "gpt-5.4",
      "model": "gpt-5.4",
      "displayName": "GPT-5.4",
      "inputModalities": ["text"]
    }
    """.utf8)

    let option = try JSONDecoder().decode(CodexModelOption.self, from: data)

    #expect(option.usesResponsesLite == false)
    #expect(option.inputModalities == ["text"])
}

@Test
func modelCatalogDecodesOpenAICompatibleModels() throws {
    let data = Data("""
    {
      "data": [
        {"id": "qwen/qwen3-coder", "object": "model"},
        {"id": "openai/gpt-oss-20b", "object": "model"}
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .lmStudio())

    #expect(models.map(\.id) == ["qwen/qwen3-coder", "openai/gpt-oss-20b"])
    #expect(models[0].isDefault)
    #expect(models[0].supportedReasoningEfforts.isEmpty)
}

@Test
func modelCatalogFallbacksTrackBundledCodexDefaults() {
    let openAI = CodexModelCatalog.fallbackModels(for: .openAI)
    let local = CodexModelCatalog.fallbackModels(for: .ollama())

    #expect(openAI.map(\.id).contains("gpt-5.3-codex"))
    #expect(openAI.first?.id == "gpt-5.4")
    #expect(openAI.first?.supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "medium", "high", "xhigh"])
    #expect(local.first?.id == "local-model")
    #expect(local.first?.supportedReasoningEfforts.isEmpty == true)
}

@Test
func authTokensResolveChatGPTAccountIDFromIDToken() throws {
    let idToken = try jwt(payload: [
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "account-123",
            "chatgpt_plan_type": "plus",
            "chatgpt_user_id": "user-123",
            "chatgpt_account_is_fedramp": false,
        ],
        "email": "dev@example.com",
    ])
    let tokens = CodexAuthTokens(idToken: idToken, accessToken: "access", refreshToken: "refresh")

    #expect(tokens.resolvedChatGPTAccountID == "account-123")
    #expect(tokens.resolvedAccountMetadata.planType == "plus")
    #expect(tokens.resolvedAccountMetadata.userID == "user-123")
    #expect(tokens.resolvedAccountMetadata.email == "dev@example.com")
}

@Test
func mobileBridgeBuildsResponsesRequest() throws {
    let body = try CodexMobileCoreBridge.buildResponsesRequest([
        "model": "gpt-5.4",
        "instructions": "Be concise",
        "input": [],
        "tools": CodexMobileCoreBridge.builtinTools(),
        "stream": true,
        "store": false,
        "reasoning": NSNull(),
        "promptCacheKey": "conversation-1",
    ])
    let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]

    #expect(value?["model"] as? String == "gpt-5.4")
    #expect(value?["instructions"] as? String == "Be concise")
    #expect((value?["tools"] as? [[String: Any]])?.first?["name"] as? String == "list_dir")
    let toolNames = Set((value?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
    #expect(toolNames.isSuperset(of: ["list_dir", "read_file", "search_files", "apply_patch", "write_file", "shell_command", "exec_command"]))
    #expect(value?["store"] as? Bool == false)
    #expect(value?["reasoning"] is NSNull)
    #expect(value?["prompt_cache_key"] as? String == "conversation-1")
}

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

#if os(macOS)
@Test
func mobileBridgeAppliesPatchWithoutMobileCoreOnMacOS() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "old\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    try "gone\n".write(to: root.appending(path: "obsolete.txt"), atomically: true, encoding: .utf8)

    let response = try CodexMobileCoreBridge.applyPatch([
        "workspaceRoot": root.path,
        "patch": """
        *** Begin Patch
        *** Update File: notes.txt
        @@
        -old
        +new
        *** Add File: nested/added.txt
        +added
        *** Delete File: obsolete.txt
        *** End Patch
        """,
    ])

    #expect(response["exit_code"] as? Int == 0)
    #expect((response["output"] as? String)?.contains("M notes.txt") == true)
    #expect((response["output"] as? String)?.contains("A nested/added.txt") == true)
    #expect((response["output"] as? String)?.contains("D obsolete.txt") == true)
    #expect(try String(contentsOf: root.appending(path: "notes.txt"), encoding: .utf8) == "new\n")
    #expect(try String(contentsOf: root.appending(path: "nested/added.txt"), encoding: .utf8) == "added\n")
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "obsolete.txt").path))
}

@Test
func mobileBridgeApplyPatchRejectsMacOSWorkspaceEscapes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let outside = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let response = try CodexMobileCoreBridge.applyPatch([
        "workspaceRoot": root.path,
        "patch": """
        *** Begin Patch
        *** Add File: \(outside.path)/escape.txt
        +bad
        *** End Patch
        """,
    ])

    #expect(response["exit_code"] as? Int == 1)
    #expect((response["output"] as? String)?.contains("escapes workspace") == true)
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "escape.txt").path))
}
#endif

@Test
func mobileBridgeBuildsTurnOptionsAndMultipartInput() throws {
    let imageData = Data([0, 1, 2])
    let inputParts = [
        CodexInput.text("look").responsesContentPart,
        CodexInput.imageData(imageData, mimeType: "image/png").responsesContentPart,
    ]
    let body = try CodexMobileCoreBridge.buildResponsesRequest([
        "model": "gpt-5.4-mini",
        "input": [["type": "message", "role": "user", "content": inputParts]],
        "tools": [],
        "stream": true,
        "store": false,
        "reasoning": ["effort": "low"],
        "serviceTier": "flex",
        "toolChoice": "required",
        "parallelToolCalls": false,
    ])
    let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let input = value?["input"] as? [[String: Any]]
    let content = input?.first?["content"] as? [[String: Any]]

    #expect(value?["model"] as? String == "gpt-5.4-mini")
    #expect(value?["service_tier"] as? String == "flex")
    #expect(value?["tool_choice"] as? String == "required")
    #expect(value?["parallel_tool_calls"] as? Bool == false)
    #expect((value?["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    #expect(content?[0]["text"] as? String == "look")
    #expect(content?[1]["image_url"] as? String == "data:image/png;base64,AAEC")
}

@Test
func sessionResponsesLiteTurnOptionsUsePersistentReasoningAndSerialTools() throws {
    let options = CodexTurnOptions(
        reasoningEffort: "medium",
        parallelToolCalls: true,
        usesResponsesLite: true
    )
    let reasoning = try #require(CodexSession.reasoningParameter(options: options) as? [String: Any])

    #expect(reasoning["effort"] as? String == "medium")
    #expect(reasoning["context"] as? String == "all_turns")
    #expect(CodexSession.parallelToolCallsParameter(options: options) == false)
}

@Test
func sessionDefaultTurnOptionsOmitResponsesLiteContext() throws {
    #expect(CodexSession.reasoningParameter(options: CodexTurnOptions()) is NSNull)
    #expect(CodexSession.parallelToolCallsParameter(options: CodexTurnOptions()) == true)
}

@Test
func subagentTurnOptionsInheritResponsesLiteMetadataWithoutModelOverride() {
    let parent = CodexTurnOptions(
        model: "gpt-5.4",
        reasoningEffort: "medium",
        parallelToolCalls: true,
        usesResponsesLite: true,
        inputModalities: ["text", "image"]
    )

    let inherited = CodexSession.subagentTurnOptions(arguments: [:], parentOptions: parent)
    let overridden = CodexSession.subagentTurnOptions(arguments: ["model": "local-model"], parentOptions: parent)

    #expect(inherited.model == "gpt-5.4")
    #expect(inherited.usesResponsesLite)
    #expect(inherited.inputModalities == ["text", "image"])
    #expect(overridden.model == "local-model")
    #expect(overridden.usesResponsesLite == false)
}

@Test
func subagentInputTextRendersStructuredTextItems() {
    let message = CodexSession.subagentInputText(from: [
        "items": [
            ["type": "input_text", "text": "First"],
            [
                "type": "message",
                "content": [
                    ["type": "text", "text": "Second"],
                    ["type": "input_image", "image_url": "data:image/png;base64,AAEC"],
                ],
            ],
        ],
    ])

    #expect(message == "First\n\nSecond")
}

@Test
func mobileBridgeNormalizesTextDelta() throws {
    let event = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.output_text.delta","item_id":"msg-1","delta":"hello"}"#.utf8)
    )

    #expect(event["type"] as? String == "outputTextDelta")
    #expect(event["itemId"] as? String == "msg-1")
    #expect(event["delta"] as? String == "hello")
}

@Test
func sessionDecodesReasoningAndToolArgumentDeltas() throws {
    let reasoning = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","delta":"working"}"#.utf8)
    )
    let arguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","output_index":0,"delta":"{\"path\""}"#.utf8)
    )

    #expect(try CodexSession.decodeStreamEvent(reasoning) == .reasoningSummaryDelta(itemID: "rs-1", delta: "working"))
    #expect(try CodexSession.decodeStreamEvent(arguments) == .toolCallInputDelta(
        itemID: "item-1",
        callID: "call-1",
        delta: #"{"path""#
    ))
}

@Test
func mobileBridgeNormalizesBothToolInputDeltaNames() throws {
    let functionArguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","delta":"{\""}"#.utf8)
    )
    let toolInput = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.tool_call_input.delta","item_id":"item-2","call_id":"call-2","delta":"path"}"#.utf8)
    )

    #expect(functionArguments["type"] as? String == "toolCallInputDelta")
    #expect(functionArguments["callId"] as? String == "call-1")
    #expect(toolInput["type"] as? String == "toolCallInputDelta")
    #expect(toolInput["itemId"] as? String == "item-2")
    #expect(toolInput["callId"] as? String == "call-2")
}

@Test
func sessionDecodesAssistantItemLifecycle() throws {
    let started = try CodexSession.decodeStreamEvent([
        "type": "outputItemAdded",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
        ],
    ])
    let completed = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "output_text", "text": "Hello"],
            ],
        ],
    ])

    #expect(started == .outputItemStarted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant")))
    #expect(completed == .outputItemCompleted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant", text: "Hello")))
}

@Test
func sessionDecodesCompletedTokenUsage() throws {
    let normalized = try CodexMobileCoreBridge.parseSSEEvent(Data("""
    {
      "type": "response.completed",
      "response": {
        "id": "resp-1",
        "usage": {
          "input_tokens": 120,
          "input_tokens_details": { "cached_tokens": 40 },
          "output_tokens": 30,
          "output_tokens_details": { "reasoning_tokens": 12 },
          "total_tokens": 150
        }
      }
    }
    """.utf8))

    guard case .completed(_, let usage) = try CodexSession.decodeStreamEvent(normalized) else {
        Issue.record("Expected completed event")
        return
    }

    #expect(usage == CodexTokenUsage(
        inputTokens: 120,
        cachedInputTokens: 40,
        outputTokens: 30,
        reasoningOutputTokens: 12,
        totalTokens: 150
    ))
}

@Test
func sessionPreservesCustomToolCallKind() throws {
    let event = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "item-1",
            "type": "custom_tool_call",
            "call_id": "call-1",
            "name": "custom",
            "input": #"{"value":1}"#,
        ],
    ])

    guard case .outputItemCompleted(let item) = event, let call = item.toolCall else {
        Issue.record("Expected completed custom tool item")
        return
    }
    #expect(call.itemID == "item-1")
    #expect(call.kind == .custom)
    #expect(call.arguments == #"{"value":1}"#)
}

@Test
func toolOutputUsesResponsesFunctionCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: false,
        name: nil
    )

    #expect(output["type"] as? String == "function_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["output"] as? String == "done")
}

@Test
func toolOutputUsesResponsesCustomToolCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: true,
        name: "custom"
    )

    #expect(output["type"] as? String == "custom_tool_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["name"] as? String == "custom")
    #expect(output["output"] as? String == "done")
}

@Test
func mobileBridgeExposesAuthRefreshAndBrowserRequests() throws {
    let refresh = try CodexMobileCoreBridge.refreshTokenRequest(
        clientID: "client",
        refreshToken: "refresh"
    )
    let authorizationURL = try CodexMobileCoreBridge.authorizationURL(
        issuer: URL(string: "https://auth.openai.com")!,
        clientID: "client",
        redirectURI: "http://localhost:1455/auth/callback",
        state: "state",
        codeChallenge: "challenge"
    )
    let token = try CodexMobileCoreBridge.authorizationCodeTokenRequest(
        clientID: "client",
        code: "code",
        codeVerifier: "verifier",
        redirectURI: "http://localhost:1455/auth/callback"
    )

    #expect((refresh["body"] as? [String: Any])?["grant_type"] as? String == "refresh_token")
    #expect(authorizationURL.absoluteString.contains("code_challenge=challenge"))
    #expect(token["path"] as? String == "/oauth/token")
    #expect(token["body"] as? String == "grant_type=authorization_code&code=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=client&code_verifier=verifier")
}

@Test
func deviceKeyPayloadUsesRustCanonicalSigningBytes() throws {
    let payload = CodexDeviceKeySignPayload.remoteControlClientConnection(.init(
        nonce: "nonce",
        sessionID: "session",
        targetOrigin: "https://chatgpt.com",
        targetPath: "/api/codex/remote/control/client",
        accountUserID: "user",
        clientID: "client",
        tokenExpiresAt: 123,
        tokenSHA256Base64URL: "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"
    ))

    let bytes = try payload.signingPayloadBytes()
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(text == #"{"domain":"codex-device-key-sign-payload/v1","payload":{"accountUserId":"user","audience":"remote_control_client_websocket","clientId":"client","nonce":"nonce","scopes":["remote_control_controller_websocket"],"sessionId":"session","targetOrigin":"https://chatgpt.com","targetPath":"/api/codex/remote/control/client","tokenExpiresAt":123,"tokenSha256Base64url":"47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU","type":"remoteControlClientConnection"}}"#)
}

@Test
func jsonSchemaBuilderProducesToolInputSchema() {
    let schema = CodexJSONSchema.object(
        properties: [
            "path": .string(description: "File path"),
            "mode": .stringEnum(["read", "write"]),
            "recursive": .boolean(),
        ],
        required: ["path"]
    )
    let properties = schema.inputSchema["properties"] as? [String: any Sendable]
    let path = properties?["path"] as? [String: any Sendable]
    let mode = properties?["mode"] as? [String: any Sendable]

    #expect(schema.inputSchema["type"] as? String == "object")
    #expect(path?["description"] as? String == "File path")
    #expect(mode?["enum"] as? [String] == ["read", "write"])
}

@Test
func workspaceStoreRoundTripsSecurityScopedWorkspaceRecord() throws {
    let suiteName = "CodexWorkspaceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let workspace = CodexWorkspace(rootURL: root, bookmarkData: Data([1, 2, 3]), readOnly: true)
    let store = CodexWorkspaceStore(defaults: defaults)

    let record = try store.save(workspace, displayName: "Demo")
    let resolved = try store.resolve(record)

    #expect(try store.list() == [record])
    #expect(resolved.rootURL.path == root.path)
    #expect(resolved.bookmarkData == Data([1, 2, 3]))
    #expect(resolved.readOnly == true)
}

@Test
func sessionExecutesBuiltinWorkspaceTools() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root),
        toolApprovalHandler: { _ in .approve }
    ))
    let listData = try await session.executeToolCall(CodexToolCall(
        callID: "call-list",
        name: "list_dir",
        arguments: #"{"dir_path":"."}"#
    ))
    let listOutput = try toolOutputBody(listData)

    let readData = try await session.executeToolCall(CodexToolCall(
        callID: "call-read",
        name: "read_file",
        arguments: #"{"path":"notes.txt"}"#
    ))
    let readOutput = try toolOutputBody(readData)

    let searchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-search",
        name: "search_files",
        arguments: #"{"query":"hello","path":"."}"#
    ))
    let searchOutput = try toolOutputBody(searchData)

    let catData = try await session.executeToolCall(CodexToolCall(
        callID: "call-cat",
        name: "shell_command",
        arguments: #"{"command":"cat notes.txt"}"#
    ))
    let catOutput = try toolOutputBody(catData)

    #expect(listOutput.contains("notes.txt"))
    #expect(readOutput == "hello\n")
    #expect(searchOutput.contains("notes.txt:1: hello"))
    #expect(catOutput == "hello\n")

    let patch = """
    *** Begin Patch
    *** Add File: added.txt
    +patched
    *** End Patch
    """
    let patchArguments = try jsonString(["patch": patch])
    let patchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-patch",
        name: "apply_patch",
        arguments: patchArguments
    ))
    let patchOutput = try toolOutputBody(patchData)

    #expect(patchOutput.contains("A added.txt"))
    #expect(try String(contentsOf: root.appending(path: "added.txt"), encoding: .utf8) == "patched\n")

    let writeData = try await session.executeToolCall(CodexToolCall(
        callID: "call-write",
        name: "write_file",
        arguments: try jsonString(["path": "written.txt", "content": "written\n"])
    ))
    let writeOutput = try toolOutputBody(writeData)

    #expect(writeOutput.contains("Wrote written.txt"))
    #expect(try String(contentsOf: root.appending(path: "written.txt"), encoding: .utf8) == "written\n")
}

@Test
func mutatingBuiltinWorkspaceToolsRequireApproval() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root)
    ))
    let data = try await session.executeToolCall(CodexToolCall(
        callID: "call-write",
        name: "write_file",
        arguments: try jsonString(["path": "denied.txt", "content": "denied\n"])
    ))
    let output = try toolOutputBody(data)

    #expect(output.contains("approval is required"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "denied.txt").path))
}

private func jwt(payload: [String: Any]) throws -> String {
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadPart = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payloadPart).signature"
}

private func toolOutputBody(_ data: Data) throws -> String {
    let item = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return item?["output"] as? String ?? ""
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private actor InMemoryGoalStore: CodexGoalStore {
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
