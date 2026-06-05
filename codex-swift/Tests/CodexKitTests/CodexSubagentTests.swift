//
//  CodexSubagentTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func subagentEnvironmentContextSummarizesOpenSubagents() {
    let context = CodexSession.subagentEnvironmentContext(statuses: [
        CodexSubagentStatus(
            agentID: "agent-1",
            taskName: "research",
            path: "/root/research",
            agentRole: "explorer",
            agentNickname: "Scout",
            status: "completed",
            finalAnswer: "Found <three> options.\nUse \"fast\" mode.",
            queuedMessages: 1,
            modelSettings: ["model": "gpt-5.5"]
        ),
        CodexSubagentStatus(
            agentID: "agent-2",
            taskName: "closed",
            path: "/root/closed",
            status: "closed"
        ),
    ])

    #expect(context?.contains("<environment_context>") == true)
    #expect(context?.contains("<subagents>") == true)
    #expect(context?.contains("- agent-1: Scout") == true)
    #expect(context?.contains("path=/root/research") == true)
    #expect(context?.contains("status=completed") == true)
    #expect(context?.contains("agent_type=explorer") == true)
    #expect(context?.contains("nickname=Scout") == true)
    #expect(context?.contains("queued_messages=1") == true)
    #expect(context?.contains("model_settings={model=gpt-5.5}") == true)
    #expect(context?.contains("Found &lt;three&gt; options. Use &quot;fast&quot; mode.") == true)
    #expect(context?.contains("agent-2") == false)
}


@Test
func subagentEnvironmentContextCapsAgentListAndFinalAnswerPreviews() {
    let longAnswer = String(repeating: "a", count: 700)
    let statuses = (1...10).map { index in
        CodexSubagentStatus(
            agentID: "agent-\(index)",
            taskName: "task_\(index)",
            path: "/root/task_\(index)",
            status: index == 1 ? "completed" : "running",
            finalAnswer: index == 1 ? longAnswer : nil
        )
    }

    let context = CodexSession.subagentEnvironmentContext(statuses: statuses)

    #expect(context?.contains("agent-1") == true)
    #expect(context?.contains("agent-8") == true)
    #expect(context?.contains("agent-9") == false)
    #expect(context?.contains("- 2 more subagents available via list_agents") == true)
    #expect(context?.contains(String(repeating: "a", count: 600) + "...") == true)
    #expect(context?.contains(String(repeating: "a", count: 650)) == false)
}


@Test
func sessionResponsesLiteTurnOptionsUsePersistentReasoningAndSerialTools() throws {
    let options = CodexTurnOptions(
        reasoningEffort: "medium",
        reasoningSummary: .detailed,
        supportsReasoningSummaries: true,
        parallelToolCalls: true,
        usesResponsesLite: true
    )
    let reasoning = try #require(CodexSession.reasoningParameter(options: options) as? [String: Any])

    #expect(reasoning["effort"] as? String == "medium")
    #expect(reasoning["summary"] as? String == "detailed")
    #expect(reasoning["context"] as? String == "all_turns")
    #expect(CodexSession.includeParameter(reasoning: reasoning) == ["reasoning.encrypted_content"])
    #expect(CodexSession.parallelToolCallsParameter(options: options) == false)
}


@Test
func sessionDefaultTurnOptionsOmitResponsesLiteContext() throws {
    #expect(CodexSession.reasoningParameter(options: CodexTurnOptions()) is NSNull)
    #expect(CodexSession.parallelToolCallsParameter(options: CodexTurnOptions()) == true)
}


@Test
func sessionTurnOptionsHonorModelReasoningAndVerbositySupport() throws {
    let unsupported = CodexTurnOptions(
        reasoningEffort: "medium",
        reasoningSummary: .auto,
        supportsReasoningSummaries: false
    )
    let verbose = CodexTurnOptions(verbosity: .low)

    #expect(CodexSession.reasoningParameter(options: unsupported) is NSNull)
    #expect(CodexSession.includeParameter(reasoning: NSNull()).isEmpty)
    #expect(CodexSession.textParameter(options: verbose)?["verbosity"] as? String == "low")
}


@Test
func subagentTurnOptionsInheritResponsesLiteMetadataWithoutModelOverride() {
    let availableModels = [
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
    ]
    let parent = CodexTurnOptions(
        model: "gpt-5.4",
        reasoningEffort: "medium",
        reasoningSummary: .concise,
        supportsReasoningSummaries: true,
        parallelToolCalls: true,
        usesResponsesLite: true,
        inputModalities: ["text", "image"],
        verbosity: .high,
        availableModelOptions: availableModels
    )

    let inherited = CodexSession.subagentTurnOptions(arguments: [:], parentOptions: parent)
    let overridden = CodexSession.subagentTurnOptions(arguments: ["model": "local-model"], parentOptions: parent)

    #expect(inherited.model == "gpt-5.4")
    #expect(inherited.usesResponsesLite)
    #expect(inherited.inputModalities == ["text", "image"])
    #expect(inherited.reasoningSummary == .concise)
    #expect(inherited.supportsReasoningSummaries == true)
    #expect(inherited.verbosity == .high)
    #expect(inherited.availableModelOptions.map(\.model) == ["gpt-5.5"])
    #expect(overridden.model == "local-model")
    #expect(overridden.usesResponsesLite == false)
    #expect(overridden.inputModalities == nil)
    #expect(overridden.supportsReasoningSummaries == nil)
    #expect(overridden.reasoningSummary == nil)
    #expect(overridden.verbosity == nil)
    #expect(overridden.availableModelOptions.map(\.model) == ["gpt-5.5"])
}


@Test
func subagentOptionsNormalizeRolesAndNicknames() {
    let reviewer = CodexSubagentRole(
        name: "reviewer",
        description: "Review code.",
        nicknameCandidates: ["Ada", "Ada", " Grace "],
        model: "gpt-5.5"
    )
    let invalid = CodexSubagentRole(name: "bad role", description: "Invalid.")
    let options = CodexSubagentOptions(isEnabled: true, roles: [reviewer, invalid])

    #expect(options.roles.map(\.name) == ["default", "reviewer"])
    #expect(options.roles[1].nicknameCandidates == ["Ada", "Grace"])
    #expect(options.roles[1].model == "gpt-5.5")
}


@Test
func subagentRoleDescriptionIncludesLockedSettings() {
    let role = CodexSubagentRole(
        name: "reviewer",
        description: "Review code.",
        model: "gpt-5.5",
        reasoningEffort: "high",
        serviceTier: "priority"
    )
    let description = CodexSession.subagentRoleDescription(roles: [role])

    #expect(description.contains("Available agent types:"))
    #expect(description.contains("`reviewer`: Review code."))
    #expect(description.contains("model=gpt-5.5"))
    #expect(description.contains("reasoning_effort=high"))
    #expect(description.contains("service_tier=priority"))
}


@Test
func subagentTurnOptionsApplyRoleOverrides() {
    let parent = CodexTurnOptions(
        model: "gpt-5.4",
        reasoningEffort: "medium",
        serviceTier: "standard",
        verbosity: .high
    )
    let role = CodexSubagentRole(
        name: "reviewer",
        description: "Review code.",
        model: "gpt-5.5",
        reasoningEffort: "high",
        serviceTier: "priority"
    )

    let options = CodexSession.subagentTurnOptions(
        arguments: [:],
        parentOptions: parent,
        role: role
    )

    #expect(options.model == "gpt-5.5")
    #expect(options.reasoningEffort == "high")
    #expect(options.serviceTier == "priority")
    #expect(options.verbosity == nil)
}


@Test
func subagentTurnOptionValidationRejectsUnavailableOverrides() {
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

    let unknownModel = CodexSession.subagentTurnOptionsValidationError(
        arguments: ["model": "unknown-model"],
        parentOptions: options
    )
    let unsupportedReasoning = CodexSession.subagentTurnOptionsValidationError(
        arguments: ["model": "gpt-5.5", "reasoning_effort": "high"],
        parentOptions: options
    )
    let unsupportedServiceTier = CodexSession.subagentTurnOptionsValidationError(
        arguments: ["model": "gpt-5.5", "service_tier": "flex"],
        parentOptions: options
    )

    #expect(unknownModel?.contains("Unknown model `unknown-model`") == true)
    #expect(unsupportedReasoning?.contains("Reasoning effort `high` is not supported") == true)
    #expect(unsupportedServiceTier?.contains("Service tier `flex` is not supported") == true)
    #expect(CodexSession.subagentTurnOptionsValidationError(
        arguments: ["model": "gpt-5.5", "reasoning_effort": "low", "service_tier": "priority"],
        parentOptions: options
    ) == nil)
}
