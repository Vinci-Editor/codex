//
//  ChatBubble.swift
//  CodexMobileDemo
//
//  Created by Ethan Lipnik.
//

import SwiftUI

struct ChatBubble: View {
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
