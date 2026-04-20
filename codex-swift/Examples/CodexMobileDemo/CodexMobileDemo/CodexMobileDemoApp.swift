import SwiftUI
import CodexKit
import UniformTypeIdentifiers

@main
struct CodexMobileDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoChatView()
        }
    }
}

struct DemoChatView: View {
    @State private var prompt = ""
    @State private var messages: [ChatMessage] = []
    @State private var provider = CodexProvider.openAI
    @State private var model = "gpt-5.4"
    @State private var session: CodexSession?
    @State private var isSending = false
    @State private var workspace: CodexWorkspace?
    @State private var isPickingWorkspace = false
    @State private var isEditingCustomModel = false
    @State private var customModelDraft = ""

    private let authStore = CodexKeychainAuthStore(account: "demo")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                settingsBar
                workspaceBar

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages) {
                        scrollToBottom(proxy)
                    }
                }
            }
            .navigationTitle("Codex")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Device Login") {
                        Task { await startDeviceLogin() }
                    }
                    .disabled(isSending)
                }
            }
            .fileImporter(
                isPresented: $isPickingWorkspace,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                selectWorkspace(result)
            }
            .alert("Custom Model", isPresented: $isEditingCustomModel) {
                TextField("Model ID", text: $customModelDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use") {
                    useCustomModel()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the exact model identifier served by this provider.")
            }
            .safeAreaBar(edge: .bottom) {
                HStack {
                    TextField("Ask Codex", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        send()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: provider) {
                model = defaultModel(for: provider)
                session = nil
            }
            .onChange(of: model) {
                session = nil
            }
            .task {
                ensureDefaultWorkspace()
            }
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 10) {
            Picker("Provider", selection: $provider) {
                Text("OpenAI").tag(CodexProvider.openAI)
                Text("LM Studio").tag(CodexProvider.lmStudio())
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)

            Menu {
                ForEach(modelOptions) { option in
                    Button {
                        model = option.id
                    } label: {
                        if model == option.id {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
                Divider()
                Button("Custom Model...") {
                    customModelDraft = model
                    isEditingCustomModel = true
                }
            } label: {
                Text(modelDisplayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.97, green: 0.98, blue: 1.0))
    }

    private var workspaceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(workspacePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Pick Folder") {
                isPickingWorkspace = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.95, green: 0.96, blue: 0.98))
    }

    private func send() {
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
            var assistantID: UUID?
            do {
                for try await event in await activeSession.submit(userText: text) {
                    switch event {
                    case .outputTextDelta(let delta):
                        if assistantID == nil {
                            assistantID = appendMessage(role: .assistant, text: "", isStreaming: true)
                        }
                        if let assistantID {
                            appendDelta(delta, to: assistantID)
                        }
                    case .toolCall(let call):
                        toolMessageIDs[call.callID] = appendMessage(
                            role: .tool,
                            text: "Running \(call.name)\n\(call.arguments)"
                        )
                    case .toolResult(let call, let output, let success):
                        let text = "\(success ? "Completed" : "Failed") \(call.name)\n\(trimToolOutput(output))"
                        if let id = toolMessageIDs[call.callID] {
                            replaceMessage(id, role: .tool, text: text, isStreaming: false)
                        } else {
                            appendMessage(role: .tool, text: text)
                        }
                    case .completed:
                        break
                    case .error(let message):
                        if let assistantID {
                            replaceMessage(assistantID, role: .error, text: message, isStreaming: false)
                        } else {
                            appendMessage(role: .error, text: message)
                        }
                    default:
                        break
                    }
                }
                if let assistantID {
                    finishStreamingMessage(assistantID)
                }
            } catch {
                if let assistantID {
                    replaceMessage(assistantID, role: .error, text: displayError(error), isStreaming: false)
                } else {
                    appendMessage(role: .error, text: displayError(error))
                }
            }
            isSending = false
        }
    }

    private func startDeviceLogin() async {
        do {
            let authenticator = CodexDeviceCodeAuthenticator()
            let code = try await authenticator.requestDeviceCode()
            appendMessage(
                role: .system,
                text: "Open \(code.verificationURL.absoluteString)\nCode: \(code.userCode)"
            )
            let tokens = try await authenticator.pollForTokens(deviceCode: code)
            try authStore.saveTokens(tokens)
            appendMessage(role: .system, text: "Signed in")
        } catch {
            appendMessage(role: .error, text: displayError(error))
        }
    }

    private func makeSession() -> CodexSession {
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
    private func appendMessage(role: ChatRole, text: String, isStreaming: Bool = false) -> UUID {
        let message = ChatMessage(role: role, text: text, isStreaming: isStreaming)
        messages.append(message)
        return message.id
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].text += delta
    }

    private func finishStreamingMessage(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].isStreaming = false
        if messages[index].text.isEmpty {
            messages[index].text = "Done."
        }
    }

    private func replaceMessage(_ id: UUID, role: ChatRole, text: String, isStreaming: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            appendMessage(role: role, text: text, isStreaming: isStreaming)
            return
        }
        messages[index].role = role
        messages[index].text = text
        messages[index].isStreaming = isStreaming
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let id = messages.last?.id else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func displayError(_ error: Error) -> String {
        if let sessionError = error as? CodexSessionError {
            switch sessionError {
            case .httpStatus(let status, let body):
                return body.isEmpty ? "HTTP \(status)" : "HTTP \(status)\n\(body)"
            case .missingAuthentication:
                return "Sign in with Device Login first."
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

    private func ensureDefaultWorkspace() {
        guard workspace == nil else {
            return
        }
        do {
            workspace = try CodexWorkspace.appContainer()
            session = nil
        } catch {
            appendMessage(role: .error, text: displayError(error))
        }
    }

    private func selectWorkspace(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }
            workspace = try CodexWorkspace.securityScopedFolder(url: url)
            session = nil
            appendMessage(role: .system, text: "Workspace set to \(url.lastPathComponent).")
        } catch {
            appendMessage(role: .error, text: displayError(error))
        }
    }

    private func useCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        model = trimmed
    }

    private var workspaceName: String {
        workspace?.rootURL.lastPathComponent ?? "No Workspace"
    }

    private var workspacePath: String {
        workspace?.rootURL.path ?? "Pick a folder so Codex can inspect files."
    }

    private var modelOptions: [ModelOption] {
        switch provider.id {
        case "openai":
            return [
                ModelOption(id: "gpt-5.4", title: "GPT-5.4"),
                ModelOption(id: "gpt-5.4-mini", title: "GPT-5.4 Mini"),
                ModelOption(id: "gpt-5.2-codex", title: "GPT-5.2 Codex"),
                ModelOption(id: "gpt-5.2", title: "GPT-5.2"),
            ]
        case "lmstudio":
            return [
                ModelOption(id: "local-model", title: "Local Model"),
                ModelOption(id: "openai/gpt-oss-20b", title: "GPT-OSS 20B"),
                ModelOption(id: "qwen/qwen3-coder", title: "Qwen3 Coder"),
            ]
        default:
            return [ModelOption(id: model, title: model)]
        }
    }

    private var modelDisplayName: String {
        modelOptions.first(where: { $0.id == model })?.title ?? model
    }

    private func defaultModel(for provider: CodexProvider) -> String {
        switch provider.id {
        case "openai":
            return "gpt-5.4"
        case "lmstudio":
            return "local-model"
        default:
            return model
        }
    }

    private var codexInstructions: String {
        """
        You are Codex, a pragmatic coding agent running on iPhone in CodexKit.
        Be direct and concrete. When the user asks about files, the workspace, or code, inspect the workspace with tools before answering.
        Use list_dir, shell_command, or exec_command to gather facts. After a tool result, continue with the answer instead of stopping at the tool call.
        Do not say you can list files later when the user asks you to inspect them; call the tool.
        """
    }

    private func trimToolOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1_200 {
            return trimmed.isEmpty ? "(no output)" : trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 1_200)
        return "\(trimmed[..<index])\n[truncated]"
    }
}

private struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: ChatRole
    var text: String
    var isStreaming = false
}

private enum ChatRole: Equatable {
    case user
    case assistant
    case system
    case tool
    case error
}

private struct ModelOption: Identifiable, Hashable {
    let id: String
    let title: String
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 56)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(labelColor)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(displayText)
                        .font(textFont)
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 310, alignment: alignment)

            if message.role != .user {
                Spacer(minLength: 56)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var displayText: String {
        if message.text.isEmpty && message.isStreaming {
            return "Thinking"
        }
        return message.text
    }

    private var label: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        case .system:
            return "Status"
        case .tool:
            return "Tool"
        case .error:
            return "Error"
        }
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var background: Color {
        switch message.role {
        case .user:
            return .black
        case .assistant:
            return .white
        case .system, .tool:
            return Color(red: 0.89, green: 0.91, blue: 0.94)
        case .error:
            return Color(red: 1.0, green: 0.90, blue: 0.90)
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : .primary
    }

    private var labelColor: Color {
        message.role == .user ? .white.opacity(0.72) : .secondary
    }

    private var textFont: Font {
        switch message.role {
        case .tool, .error:
            return .body.monospaced()
        case .user, .assistant, .system:
            return .body
        }
    }
}

struct EchoTool: CodexTool {
    let name = "echo_demo"
    let description = "Echoes the provided text."
    let inputSchema: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "text": ["type": "string"],
        ],
        "required": ["text"],
        "additionalProperties": false,
    ]

    func execute(call: CodexToolCall, context: CodexToolContext) async throws -> CodexToolResult {
        CodexToolResult(output: call.arguments)
    }
}
