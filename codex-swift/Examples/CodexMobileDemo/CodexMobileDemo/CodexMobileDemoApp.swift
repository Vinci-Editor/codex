import SwiftUI
import CodexKit

@main
struct CodexMobileDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoChatView()
        }
    }
}

struct DemoChatView: View {
    @State var prompt = ""
    @State var messages: [ChatMessage] = []
    @State var provider = CodexProvider.openAI
    @State var model = "gpt-5.5"
    @State var session: CodexSession?
    @State var isSending = false
    @State var isSigningIn = false
    @State var workspace: CodexWorkspace?
    @State var isPickingWorkspace = false
    @State var isEditingCustomModel = false
    @State var customModelDraft = ""

    let authStore = CodexKeychainAuthStore(account: "demo")

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
                    Menu {
                        Button {
                            Task { await startBrowserLogin() }
                        } label: {
                            Label("Browser Login", systemImage: "globe")
                        }
                        Button {
                            Task { await startDeviceLogin() }
                        } label: {
                            Label("Device Login", systemImage: "rectangle.and.pencil.and.ellipsis")
                        }
                    } label: {
                        Label(isSigningIn ? "Signing In" : "Sign In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(isSending || isSigningIn)
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
}
