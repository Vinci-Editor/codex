import Foundation
import CodexMobileCoreBridge

public struct CodexProvider: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let requiresChatGPTAuth: Bool
    public let defaultHeaders: [String: String]

    public init(
        id: String,
        name: String,
        baseURL: URL,
        requiresChatGPTAuth: Bool,
        defaultHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.requiresChatGPTAuth = requiresChatGPTAuth
        self.defaultHeaders = defaultHeaders
    }

    public static let openAI = CodexProvider(
        id: "openai",
        name: "OpenAI",
        baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
        requiresChatGPTAuth: true,
        defaultHeaders: ["version": "0.0.0"]
    )

    public static func lmStudio(baseURL: URL = URL(string: "http://127.0.0.1:1234/v1")!) -> CodexProvider {
        CodexProvider(id: "lmstudio", name: "LM Studio", baseURL: baseURL, requiresChatGPTAuth: false)
    }

    public static func ollama(baseURL: URL = URL(string: "http://127.0.0.1:11434/v1")!) -> CodexProvider {
        CodexProvider(id: "ollama", name: "Ollama", baseURL: baseURL, requiresChatGPTAuth: false)
    }

    public static func custom(
        id: String,
        name: String,
        baseURL: URL,
        requiresChatGPTAuth: Bool = false,
        headers: [String: String] = [:]
    ) -> CodexProvider {
        CodexProvider(id: id, name: name, baseURL: baseURL, requiresChatGPTAuth: requiresChatGPTAuth, defaultHeaders: headers)
    }

    public static func defaults() -> [CodexProvider] {
        CodexMobileCoreBridge.providerDefaults().compactMap { value in
            guard
                let id = value["id"] as? String,
                let name = value["name"] as? String,
                let base = value["baseUrl"] as? String,
                let url = URL(string: base)
            else {
                return nil
            }
            return CodexProvider(
                id: id,
                name: name,
                baseURL: url,
                requiresChatGPTAuth: value["requiresChatgptAuth"] as? Bool ?? false
            )
        }
    }

    func responsesURL() -> URL {
        baseURL.appending(path: "responses")
    }
}
