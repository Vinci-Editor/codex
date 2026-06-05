//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

let maxSubagentModelOverrideDescriptions = 8
let maxSubagentEnvironmentContextAgents = 8
let maxSubagentEnvironmentContextPreviewCharacters = 600
typealias CodexSubagentStatusHandler = @Sendable (CodexSubagentStatus) async -> Void
typealias CodexSubagentEventHandler = @Sendable (CodexSubagentEvent) async -> Void

public struct CodexCompactionOptions: Codable, Sendable, Equatable, Hashable {
    public let automaticTriggerApproxTokens: Int?

    public init(automaticTriggerApproxTokens: Int? = nil) {
        self.automaticTriggerApproxTokens = automaticTriggerApproxTokens.map { max($0, 1) }
    }

    public static let disabled = CodexCompactionOptions()

    public static func automatic(triggerApproxTokens: Int = 200_000) -> CodexCompactionOptions {
        CodexCompactionOptions(automaticTriggerApproxTokens: triggerApproxTokens)
    }
}

public struct CodexSessionConfiguration: Sendable {
    public let provider: CodexProvider
    public let model: String
    public let authStore: (any CodexAuthStore)?
    public let apiKeyStore: (any CodexAPIKeyStore)?
    public let chatGPTAuthenticator: CodexDeviceCodeAuthenticator?
    public let workspace: CodexWorkspace?
    public let baseInstructionsOverride: String?
    public let additionalDeveloperInstructions: String?
    public let contextualUserInstructions: String?
    public let tools: [any CodexTool]
    public let subagentOptions: CodexSubagentOptions
    public let webSearch: CodexWebSearchOptions?
    public let compactionOptions: CodexCompactionOptions
    public let urlSession: URLSession
    public let toolApprovalHandler: CodexToolApprovalHandler?

    public init(
        provider: CodexProvider = .openAI,
        model: String = "gpt-5.5",
        authStore: (any CodexAuthStore)? = nil,
        apiKeyStore: (any CodexAPIKeyStore)? = nil,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator? = nil,
        workspace: CodexWorkspace? = nil,
        baseInstructionsOverride: String? = nil,
        additionalDeveloperInstructions: String? = nil,
        contextualUserInstructions: String? = nil,
        tools: [any CodexTool] = [],
        subagentOptions: CodexSubagentOptions = .disabled,
        webSearch: CodexWebSearchOptions? = nil,
        compactionOptions: CodexCompactionOptions = .disabled,
        urlSession: URLSession = .shared,
        toolApprovalHandler: CodexToolApprovalHandler? = nil
    ) {
        self.provider = provider
        self.model = model
        self.authStore = authStore
        self.apiKeyStore = apiKeyStore
        self.chatGPTAuthenticator = chatGPTAuthenticator
        self.workspace = workspace
        self.baseInstructionsOverride = baseInstructionsOverride
        self.additionalDeveloperInstructions = additionalDeveloperInstructions
        self.contextualUserInstructions = contextualUserInstructions
        self.tools = tools
        self.subagentOptions = subagentOptions
        self.webSearch = webSearch
        self.compactionOptions = compactionOptions
        self.urlSession = urlSession
        self.toolApprovalHandler = toolApprovalHandler
    }

    public func withToolApprovalHandler(_ handler: CodexToolApprovalHandler?) -> CodexSessionConfiguration {
        CodexSessionConfiguration(
            provider: provider,
            model: model,
            authStore: authStore,
            apiKeyStore: apiKeyStore,
            chatGPTAuthenticator: chatGPTAuthenticator,
            workspace: workspace,
            baseInstructionsOverride: baseInstructionsOverride,
            additionalDeveloperInstructions: additionalDeveloperInstructions,
            contextualUserInstructions: contextualUserInstructions,
            tools: tools,
            subagentOptions: subagentOptions,
            webSearch: webSearch,
            compactionOptions: compactionOptions,
            urlSession: urlSession,
            toolApprovalHandler: handler
        )
    }

    public func withAdditionalTools(_ additionalTools: [any CodexTool]) -> CodexSessionConfiguration {
        CodexSessionConfiguration(
            provider: provider,
            model: model,
            authStore: authStore,
            apiKeyStore: apiKeyStore,
            chatGPTAuthenticator: chatGPTAuthenticator,
            workspace: workspace,
            baseInstructionsOverride: baseInstructionsOverride,
            additionalDeveloperInstructions: additionalDeveloperInstructions,
            contextualUserInstructions: contextualUserInstructions,
            tools: tools + additionalTools,
            subagentOptions: subagentOptions,
            webSearch: webSearch,
            compactionOptions: compactionOptions,
            urlSession: urlSession,
            toolApprovalHandler: toolApprovalHandler
        )
    }
}

public struct CodexOutputItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case assistantMessage
        case reasoning
        case functionCall
        case customToolCall
        case webSearchCall
        case unknown
    }

    public let id: String
    public let kind: Kind
    public let role: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let text: String?

    public init(
        id: String,
        kind: Kind,
        role: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        text: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.text = text
    }

    public var toolCall: CodexToolCall? {
        guard
            let callID,
            let name,
            kind == .functionCall || kind == .customToolCall
        else {
            return nil
        }
        return CodexToolCall(
            itemID: id,
            callID: callID,
            name: name,
            arguments: arguments ?? "{}",
            kind: kind == .customToolCall ? .custom : .function
        )
    }
}

public struct CodexWebSearchCall: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let status: String?
    public let actionType: String
    public let detail: String

    public init(id: String, status: String? = nil, actionType: String = "other", detail: String = "") {
        self.id = id
        self.status = status
        self.actionType = actionType
        self.detail = detail
    }

    public var isCompleted: Bool {
        status == nil || status == "completed"
    }
}

public enum CodexStreamEvent: Sendable, Equatable {
    case created
    case outputItemStarted(CodexOutputItem)
    case outputItemCompleted(CodexOutputItem)
    case outputTextDelta(itemID: String?, delta: String)
    case reasoningSummaryDelta(itemID: String?, delta: String)
    case toolCallInputDelta(itemID: String?, callID: String?, delta: String)
    case toolOutputDelta(CodexToolCall, String)
    case outputItemAdded(Data)
    case outputItemDone(Data)
    case completed(Data, CodexTokenUsage?)
    case planUpdated(CodexPlanUpdate)
    case webSearch(CodexWebSearchCall)
    case contextCompacted(CodexCompactionResult)
    case subagentStatus(CodexSubagentStatus)
    indirect case subagentEvent(CodexSubagentEvent)
    case toolCall(CodexToolCall)
    case toolResult(CodexToolCall, String, Bool)
    case error(String)
    case raw(Data)
}

public struct CodexSubagentStatus: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let agentID: String
    public let taskName: String
    public let path: String
    public let agentRole: String?
    public let agentNickname: String?
    public let status: String
    public let finalAnswer: String?
    public let error: String?
    public let queuedMessages: Int
    public let queuedFollowups: Int
    public let modelSettings: [String: String]

    public var id: String { agentID }

    public init(
        agentID: String,
        taskName: String,
        path: String,
        agentRole: String? = nil,
        agentNickname: String? = nil,
        status: String,
        finalAnswer: String? = nil,
        error: String? = nil,
        queuedMessages: Int = 0,
        queuedFollowups: Int = 0,
        modelSettings: [String: String] = [:]
    ) {
        self.agentID = agentID
        self.taskName = taskName
        self.path = path
        self.agentRole = agentRole
        self.agentNickname = agentNickname
        self.status = status
        self.finalAnswer = finalAnswer
        self.error = error
        self.queuedMessages = queuedMessages
        self.queuedFollowups = queuedFollowups
        self.modelSettings = modelSettings
    }
}

public struct CodexSubagentEvent: Sendable, Equatable {
    public let agent: CodexSubagentStatus
    public let event: CodexStreamEvent

    public init(agent: CodexSubagentStatus, event: CodexStreamEvent) {
        self.agent = agent
        self.event = event
    }
}

public struct CodexSessionSnapshot: Codable, Sendable, Equatable, Hashable {
    public let historyJSON: Data

    public init(historyJSON: Data) {
        self.historyJSON = historyJSON
    }
}

public struct CodexCompactionResult: Codable, Sendable, Equatable, Hashable {
    public let summary: String
    public let originalItemCount: Int
    public let compactedItemCount: Int

    public init(summary: String, originalItemCount: Int, compactedItemCount: Int) {
        self.summary = summary
        self.originalItemCount = originalItemCount
        self.compactedItemCount = compactedItemCount
    }
}
