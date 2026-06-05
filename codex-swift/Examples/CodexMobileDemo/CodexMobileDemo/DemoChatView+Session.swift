//
//  DemoChatView+Session.swift
//  CodexMobileDemo
//
//  Created by Ethan Lipnik.
//

import CodexKit
import SwiftUI

extension DemoChatView {
    func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }
        prompt = ""
        isSending = true
        appendMessage(role: .user, text: text)
        let activeSession = session ?? makeSession()
        session = activeSession

        Task {
            var toolMessageIDs: [String: UUID] = [:]
            var assistantMessageIDs: [String: UUID] = [:]
            var activeAssistantItemID: String?
            var fallbackAssistantItemID: String?

            func assistantKey(for itemID: String?) -> String {
                if let itemID, !itemID.isEmpty {
                    return itemID
                }
                if let activeAssistantItemID {
                    return activeAssistantItemID
                }
                if let fallbackAssistantItemID {
                    return fallbackAssistantItemID
                }
                let key = "assistant-\(assistantMessageIDs.count + 1)"
                fallbackAssistantItemID = key
                return key
            }

            do {
                for try await event in await activeSession.submit(userText: text) {
                    switch event {
                    case .outputItemStarted(let item) where item.kind == .assistantMessage:
                        activeAssistantItemID = item.id
                        fallbackAssistantItemID = item.id
                        if assistantMessageIDs[item.id] == nil {
                            assistantMessageIDs[item.id] = appendMessage(role: .assistant, text: "", isStreaming: true)
                        }
                    case .outputTextDelta(let itemID, let delta):
                        let key = assistantKey(for: itemID)
                        activeAssistantItemID = key
                        if assistantMessageIDs[key] == nil {
                            assistantMessageIDs[key] = appendMessage(role: .assistant, text: "", isStreaming: true)
                        }
                        if let assistantID = assistantMessageIDs[key] {
                            appendDelta(delta, to: assistantID)
                        }
                    case .outputItemCompleted(let item) where item.kind == .assistantMessage:
                        if let assistantID = assistantMessageIDs[item.id] {
                            finishStreamingMessage(assistantID)
                        }
                        if activeAssistantItemID == item.id {
                            activeAssistantItemID = nil
                        }
                    case .toolCall(let call):
                        toolMessageIDs[call.itemID ?? call.callID] = appendMessage(
                            role: .tool,
                            text: "Running \(call.name)\n\(call.arguments)"
                        )
                    case .toolOutputDelta(let call, let delta):
                        let key = call.itemID ?? call.callID
                        if let id = toolMessageIDs[key] {
                            appendDelta(delta, to: id)
                        } else {
                            toolMessageIDs[key] = appendMessage(
                                role: .tool,
                                text: "Running \(call.name)\n\(delta)",
                                isStreaming: true
                            )
                        }
                    case .toolResult(let call, let output, let success):
                        let text = "\(success ? "Completed" : "Failed") \(call.name)\n\(trimToolOutput(output))"
                        if let id = toolMessageIDs[call.itemID ?? call.callID] {
                            replaceMessage(id, role: .tool, text: text, isStreaming: false)
                        } else {
                            appendMessage(role: .tool, text: text)
                        }
                    case .completed:
                        break
                    case .error(let message):
                        if let assistantID = activeAssistantItemID.flatMap({ assistantMessageIDs[$0] }) {
                            replaceMessage(assistantID, role: .error, text: message, isStreaming: false)
                        } else {
                            appendMessage(role: .error, text: message)
                        }
                    default:
                        break
                    }
                }
                for assistantID in assistantMessageIDs.values {
                    finishStreamingMessage(assistantID)
                }
            } catch {
                if let assistantID = activeAssistantItemID.flatMap({ assistantMessageIDs[$0] }) {
                    replaceMessage(assistantID, role: .error, text: displayError(error), isStreaming: false)
                } else {
                    appendMessage(role: .error, text: displayError(error))
                }
            }
            isSending = false
        }
    }

    @MainActor
    func startBrowserLogin() async {
        guard !isSigningIn else {
            return
        }
        isSigningIn = true
        defer {
            isSigningIn = false
        }

        do {
            let authenticator = CodexBrowserAuthenticator()
            let tokens = try await authenticator.authenticate()
            try saveSignedInTokens(tokens, source: "browser")
        } catch {
            appendMessage(role: .error, text: displayError(error))
        }
    }

    @MainActor
    func startDeviceLogin() async {
        guard !isSigningIn else {
            return
        }
        isSigningIn = true
        defer {
            isSigningIn = false
        }

        do {
            let authenticator = CodexDeviceCodeAuthenticator()
            let code = try await authenticator.requestDeviceCode()
            appendMessage(
                role: .system,
                text: "Open \(code.verificationURL.absoluteString)\nCode: \(code.userCode)"
            )
            let tokens = try await authenticator.pollForTokens(deviceCode: code)
            try saveSignedInTokens(tokens, source: "device")
        } catch {
            appendMessage(role: .error, text: displayError(error))
        }
    }

    func saveSignedInTokens(_ tokens: CodexAuthTokens, source: String) throws {
        try authStore.saveTokens(tokens)
        session = nil

        let metadata = tokens.resolvedAccountMetadata
        let account = metadata.email ?? metadata.accountID ?? "ChatGPT account"
        let plan = metadata.planType.map { " (\($0))" } ?? ""
        appendMessage(role: .system, text: "Signed in with \(source) login: \(account)\(plan).")
    }

    func makeSession() -> CodexSession {
        let configuration = CodexSessionConfiguration(
            provider: provider,
            model: model,
            authStore: authStore,
            workspace: workspace,
            baseInstructionsOverride: codexInstructions,
            additionalDeveloperInstructions: "You are running inside the CodexMobileDemo app.",
            tools: [EchoTool()]
        )
        return CodexSession(configuration: configuration)
    }

    @discardableResult
    func appendMessage(role: ChatRole, text: String, isStreaming: Bool = false) -> UUID {
        let message = ChatMessage(role: role, text: text, isStreaming: isStreaming)
        messages.append(message)
        return message.id
    }

    func appendDelta(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].text += delta
    }

    func finishStreamingMessage(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].isStreaming = false
        if messages[index].text.isEmpty {
            messages[index].text = "Done."
        }
    }

    func replaceMessage(_ id: UUID, role: ChatRole, text: String, isStreaming: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            appendMessage(role: role, text: text, isStreaming: isStreaming)
            return
        }
        messages[index].role = role
        messages[index].text = text
        messages[index].isStreaming = isStreaming
    }

    func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let id = messages.last?.id else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    func displayError(_ error: Error) -> String {
        if let sessionError = error as? CodexSessionError {
            switch sessionError {
            case .httpStatus(let status, let body):
                return body.isEmpty ? "HTTP \(status)" : "HTTP \(status)\n\(body)"
            case .missingAuthentication:
                return "Sign in with Browser Login or Device Login first."
            case .unknownTool(let name):
                return "Unknown tool: \(name)"
            case .workspacePathError(let message):
                return message
            case .toolLoopLimitExceeded:
                return "Tool loop limit exceeded."
            }
        }
        return String(describing: error)
    }

    var codexInstructions: String {
        """
        You are Codex, a pragmatic coding agent running on iPhone in CodexKit.
        Be direct and concrete. When the user asks about files, the workspace, or code, inspect the workspace with tools before answering.
        Use list_dir, shell_command, or exec_command to gather facts. After a tool result, continue with the answer instead of stopping at the tool call.
        Do not say you can list files later when the user asks you to inspect them; call the tool.
        """
    }

    func trimToolOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1_200 {
            return trimmed.isEmpty ? "(no output)" : trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 1_200)
        return "\(trimmed[..<index])\n[truncated]"
    }
}
