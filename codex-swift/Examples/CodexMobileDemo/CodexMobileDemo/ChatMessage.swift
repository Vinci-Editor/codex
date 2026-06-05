//
//  ChatMessage.swift
//  CodexMobileDemo
//
//  Created by Ethan Lipnik.
//

import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: ChatRole
    var text: String
    var isStreaming = false
}

enum ChatRole: Equatable {
    case user
    case assistant
    case system
    case tool
    case error
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let title: String
}
