import AuthenticationServices
import Foundation
import CodexMobileCoreBridge

public struct CodexBrowserAuthenticationConfiguration: Sendable, Equatable {
    public let issuer: URL
    public let clientID: String
    public let callbackBindHost: String
    public let callbackPublicHost: String
    public let callbackPort: UInt16
    public let callbackPath: String
    public let callbackTimeout: Duration
    public let prefersEphemeralWebBrowserSession: Bool

    public init(
        issuer: URL = URL(string: "https://auth.openai.com")!,
        clientID: String = CodexDeviceCodeAuthenticator.defaultClientID,
        callbackBindHost: String = "127.0.0.1",
        callbackPublicHost: String = "localhost",
        callbackPort: UInt16 = 1455,
        callbackPath: String = "/auth/callback",
        callbackTimeout: Duration = .seconds(600),
        prefersEphemeralWebBrowserSession: Bool = true
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.callbackBindHost = callbackBindHost
        self.callbackPublicHost = callbackPublicHost
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.callbackTimeout = callbackTimeout
        self.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
    }
}

@MainActor
public final class CodexBrowserAuthenticator: NSObject, @unchecked Sendable {
    private let configuration: CodexBrowserAuthenticationConfiguration
    private let session: URLSession
    private let presentationProvider: CodexBrowserPresentationProvider
    private var activeAttempt: CodexBrowserAuthAttempt?

    public init(
        configuration: CodexBrowserAuthenticationConfiguration = CodexBrowserAuthenticationConfiguration(),
        session: URLSession = .shared,
        presentationAnchor: (@MainActor @Sendable () -> ASPresentationAnchor)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.presentationProvider = CodexBrowserPresentationProvider(anchor: presentationAnchor)
    }

    public func authenticate() async throws -> CodexAuthTokens {
        activeAttempt?.cancel()

        let state = UUID().uuidString
        let codeVerifier = Self.generatePKCECodeVerifier()
        let codeChallenge = Self.generatePKCECodeChallenge(codeVerifier)
        let callbackServer = try CodexLoopbackCallbackServer(
            publicHost: configuration.callbackPublicHost,
            port: configuration.callbackPort,
            path: configuration.callbackPath,
            timeout: configuration.callbackTimeout
        )
        let redirectURI = try await callbackServer.start()
        let authorizeURL = try CodexMobileCoreBridge.authorizationURL(
            issuer: configuration.issuer,
            clientID: configuration.clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge
        )
        let callbackURL = try await runWebAuthentication(
            authorizeURL: authorizeURL,
            callbackServer: callbackServer
        )
        let code = try Self.authorizationCode(
            from: callbackURL,
            expectedState: state,
            configuration: configuration
        )
        return try await exchangeAuthorizationCode(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
    }

    private func runWebAuthentication(
        authorizeURL: URL,
        callbackServer: CodexLoopbackCallbackServer
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = CodexBrowserAuthAttempt(
                callbackServer: callbackServer,
                continuation: continuation
            )
            activeAttempt = attempt
            attempt.callbackTask = Task { [weak attempt] in
                do {
                    let callbackURL = try await callbackServer.waitForCallback()
                    await MainActor.run {
                        attempt?.finish(.success(callbackURL))
                    }
                } catch {
                    await MainActor.run {
                        attempt?.finish(.failure(error))
                    }
                }
            }

            let completionHandler = CodexWebAuthenticationCompletionHandler(attempt: attempt)
            attempt.completionHandler = completionHandler
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: nil,
                completionHandler: completionHandler.handle(callbackURL:error:)
            )
            session.prefersEphemeralWebBrowserSession = configuration.prefersEphemeralWebBrowserSession
            session.presentationContextProvider = presentationProvider
            attempt.session = session
            guard session.start() else {
                attempt.finish(.failure(CodexBrowserAuthError.unableToStartSession))
                return
            }
        }
    }

    private func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> CodexAuthTokens {
        let descriptor = try CodexMobileCoreBridge.authorizationCodeTokenRequest(
            clientID: configuration.clientID,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
        let tokens = try await performTokenRequest(descriptor)
        guard let refreshToken = tokens.refreshToken else {
            throw CodexBrowserAuthError.missingRefreshToken
        }
        let metadata = CodexAuthTokens.accountMetadata(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken
        )
        guard let accountID = metadata.accountID else {
            throw CodexBrowserAuthError.missingAccountID
        }
        return CodexAuthTokens(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            planType: metadata.planType
        )
    }

    private func performTokenRequest(_ descriptor: [String: Any]) async throws -> BrowserTokenResponse {
        let path = descriptor["path"] as? String ?? "/oauth/token"
        let url = configuration.issuer.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = descriptor["method"] as? String ?? "POST"
        if let headers = descriptor["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = descriptor["body"] as? String {
            request.httpBody = Data(body.utf8)
        } else if let body = descriptor["body"] as? [String: Any] {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexBrowserAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexBrowserAuthError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(BrowserTokenResponse.self, from: data)
    }

    private static func authorizationCode(
        from callbackURL: URL,
        expectedState: String,
        configuration: CodexBrowserAuthenticationConfiguration
    ) throws -> String {
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            callbackURL.scheme == "http",
            components.host == configuration.callbackPublicHost,
            components.path == configuration.callbackPath
        else {
            throw CodexBrowserAuthError.invalidCallbackURL
        }
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        if let error = queryItems["error"], !error.isEmpty {
            throw CodexBrowserAuthError.oauthError(queryItems["error_description"] ?? error)
        }
        guard queryItems["state"] == expectedState else {
            throw CodexBrowserAuthError.stateMismatch
        }
        guard let code = queryItems["code"], !code.isEmpty else {
            throw CodexBrowserAuthError.missingAuthorizationCode
        }
        return code
    }

}

public enum CodexBrowserAuthError: Error, Equatable {
    case unableToStartSession
    case cancelled
    case callbackTimedOut
    case invalidCallbackURL
    case missingAuthorizationCode
    case missingRefreshToken
    case missingAccountID
    case stateMismatch
    case oauthError(String)
    case invalidResponse
    case httpStatus(Int, String)
}
