import Foundation

enum CodexAuthorization {
    static func apply(
        to request: inout URLRequest,
        provider: CodexProvider,
        authStore: (any CodexAuthStore)?,
        apiKeyStore: (any CodexAPIKeyStore)?,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator?,
        missingAuthentication: @autoclosure () -> any Error
    ) async throws {
        switch provider.authMode {
        case .none:
            break
        case .chatGPT:
            let tokens = try await chatGPTTokens(
                authStore: authStore,
                chatGPTAuthenticator: chatGPTAuthenticator,
                missingAuthentication: missingAuthentication()
            )
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = tokens.resolvedChatGPTAccountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
        case .apiKey:
            guard let apiKey = try apiKeyStore?.loadAPIKey(), !apiKey.isEmpty else {
                throw missingAuthentication()
            }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func chatGPTTokens(
        authStore: (any CodexAuthStore)?,
        chatGPTAuthenticator: CodexDeviceCodeAuthenticator?,
        missingAuthentication: @autoclosure () -> any Error
    ) async throws -> CodexAuthTokens {
        guard let authStore, var tokens = try authStore.loadTokens() else {
            throw missingAuthentication()
        }
        if tokens.shouldRefresh() {
            let authenticator = chatGPTAuthenticator ?? CodexDeviceCodeAuthenticator()
            tokens = try await authenticator.refreshTokens(tokens)
            try authStore.saveTokens(tokens)
        }
        return tokens
    }
}
