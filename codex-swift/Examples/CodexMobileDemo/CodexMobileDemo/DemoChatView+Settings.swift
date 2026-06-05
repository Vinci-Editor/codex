//
//  DemoChatView+Settings.swift
//  CodexMobileDemo
//
//  Created by Ethan Lipnik.
//

import CodexKit
import SwiftUI
import UniformTypeIdentifiers

extension DemoChatView {
    var settingsBar: some View {
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

    var workspaceBar: some View {
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

    func ensureDefaultWorkspace() {
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

    func selectWorkspace(_ result: Result<[URL], Error>) {
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

    func useCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        model = trimmed
    }

    var workspaceName: String {
        workspace?.rootURL.lastPathComponent ?? "No Workspace"
    }

    var workspacePath: String {
        workspace?.rootURL.path ?? "Pick a folder so Codex can inspect files."
    }

    var modelOptions: [ModelOption] {
        switch provider.id {
        case "openai":
            return [
                ModelOption(id: "gpt-5.5", title: "GPT-5.5"),
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

    var modelDisplayName: String {
        modelOptions.first(where: { $0.id == model })?.title ?? model
    }

    func defaultModel(for provider: CodexProvider) -> String {
        switch provider.id {
        case "openai":
            return "gpt-5.5"
        case "lmstudio":
            return "local-model"
        default:
            return model
        }
    }
}
