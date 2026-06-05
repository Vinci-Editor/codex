//
//  CodexSubagentSpawnTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func subagentSpawnValidationRejectsFullHistoryModelOverrides() {
    let options = CodexTurnOptions(
        model: "gpt-5.5",
        reasoningEffort: "medium",
        serviceTier: "priority",
        availableModelOptions: [
            CodexModelOption(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                defaultReasoningEffort: "medium",
                supportedReasoningEfforts: [
                    CodexReasoningEffortOption(reasoningEffort: "low"),
                    CodexReasoningEffortOption(reasoningEffort: "medium"),
                ],
                serviceTiers: [
                    CodexServiceTierOption(id: "priority", name: "Priority"),
                ]
            ),
        ]
    )

    let defaultForkModelOverride = CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["model": "gpt-5.4"],
        parentOptions: options
    )
    let explicitFullForkReasoningOverride = CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "all", "reasoning_effort": "low"],
        parentOptions: options
    )
    let explicitFullForkAgentType = CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["agent_type": "explorer"],
        parentOptions: options
    )

    #expect(defaultForkModelOverride?.contains("Full-history forked agents inherit") == true)
    #expect(explicitFullForkReasoningOverride?.contains("Full-history forked agents inherit") == true)
    #expect(explicitFullForkAgentType?.contains("parent agent type") == true)
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "none", "model": "gpt-5.5"],
        parentOptions: options
    ) == nil)
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "2", "reasoning_effort": "low"],
        parentOptions: options
    ) == nil)
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "all", "service_tier": "priority"],
        parentOptions: options
    ) == nil)
}


@Test
func subagentSpawnValidationRejectsRoleLockedOverrides() {
    let role = CodexSubagentRole(
        name: "reviewer",
        description: "Review code.",
        model: "gpt-5.5",
        reasoningEffort: "high",
        serviceTier: "priority"
    )

    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "none", "model": "gpt-5.4"],
        parentOptions: nil,
        role: role
    ) == "agent_type `reviewer` sets its own model; omit model for spawn_agent.")
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "none", "reasoning_effort": "low"],
        parentOptions: nil,
        role: role
    ) == "agent_type `reviewer` sets its own reasoning effort; omit reasoning_effort for spawn_agent.")
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "none", "service_tier": "standard"],
        parentOptions: nil,
        role: role
    ) == "agent_type `reviewer` sets its own service tier; omit service_tier for spawn_agent.")
}


@Test
func subagentSpawnValidationRejectsInvalidForkTurns() {
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_context": true],
        parentOptions: nil
    ) == "fork_context is not supported; use fork_turns instead.")
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "banana"],
        parentOptions: nil
    ) == "fork_turns must be `none`, `all`, or a positive integer string.")
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "0"],
        parentOptions: nil
    ) == "fork_turns must be `none`, `all`, or a positive integer string.")
    #expect(CodexSession.subagentSpawnArgumentsValidationError(
        arguments: ["fork_turns": "1"],
        parentOptions: nil
    ) == nil)
}


@Test
func subagentOptionsNormalizeDepthLimit() {
    let unlimited = CodexSubagentOptions(isEnabled: true)
    let clamped = CodexSubagentOptions(isEnabled: true, maxDepth: 0)

    #expect(unlimited.maxDepth == nil)
    #expect(clamped.maxDepth == 1)
}


@Test
func subagentDepthTreatsRootAsDepthZero() {
    #expect(CodexSession.subagentDepth(path: "/root") == 0)
    #expect(CodexSession.subagentDepth(path: "/root/research") == 1)
    #expect(CodexSession.subagentDepth(path: "/root/research/audit") == 2)
    #expect(CodexSession.subagentDepth(path: "/scratch") == 1)
}


@Test
func subagentTurnOptionValidationAllowsSparseLocalModelCatalogs() {
    #expect(CodexSession.subagentTurnOptionsValidationError(
        arguments: ["model": "local-model", "reasoning_effort": "high", "service_tier": "priority"],
        parentOptions: CodexTurnOptions()
    ) == nil)
}


@Test
func subagentModelOverrideDescriptionIncludesPickerVisibleModelMetadata() {
    let options = CodexTurnOptions(
        model: "gpt-5.4",
        reasoningEffort: "medium",
        serviceTier: "priority",
        availableModelOptions: [
            CodexModelOption(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                description: "Frontier model",
                defaultReasoningEffort: "medium",
                supportedReasoningEfforts: [
                    CodexReasoningEffortOption(reasoningEffort: "low"),
                    CodexReasoningEffortOption(reasoningEffort: "medium"),
                ],
                serviceTiers: [
                    CodexServiceTierOption(id: "priority", name: "Priority"),
                ]
            ),
            CodexModelOption(
                id: "hidden",
                model: "hidden",
                displayName: "Hidden",
                isHidden: true
            ),
        ]
    )

    let description = CodexSession.subagentModelOverrideDescription(options: options)
    let guidance = CodexSession.subagentInheritedModelGuidance(options: options)

    #expect(description.contains("Available model overrides"))
    #expect(description.contains("`gpt-5.5`"))
    #expect(description.contains("medium (default)"))
    #expect(description.contains("Service tiers: priority"))
    #expect(!description.contains("hidden"))
    #expect(guidance.contains("inherit `gpt-5.4`"))
    #expect(guidance.contains("inherit `medium`"))
    #expect(guidance.contains("inherit `priority`"))
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
