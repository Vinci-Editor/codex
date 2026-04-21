import AuthenticationServices
import CryptoKit
import Foundation
import Network
import CodexMobileCoreBridge

#if canImport(Security)
import Security
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: nil
            ) { [weak attempt] _, error in
                Task { @MainActor in
                    guard let error else {
                        attempt?.finish(.failure(CodexBrowserAuthError.cancelled))
                        return
                    }
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        attempt?.finish(.failure(CodexBrowserAuthError.cancelled))
                    } else {
                        attempt?.finish(.failure(error))
                    }
                }
            }
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

    private static func generatePKCECodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        #else
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        #endif
        return base64URL(Data(bytes))
    }

    private static func generatePKCECodeChallenge(_ codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct BrowserTokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

@MainActor
private final class CodexBrowserAuthAttempt {
    var session: ASWebAuthenticationSession?
    var callbackTask: Task<Void, Never>?

    private let callbackServer: CodexLoopbackCallbackServer
    private let continuation: CheckedContinuation<URL, Error>
    private var didFinish = false

    init(
        callbackServer: CodexLoopbackCallbackServer,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.callbackServer = callbackServer
        self.continuation = continuation
    }

    func finish(_ result: Result<URL, Error>) {
        guard !didFinish else {
            return
        }
        didFinish = true
        callbackTask?.cancel()
        callbackTask = nil
        callbackServer.stop()
        session?.cancel()
        session = nil
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.failure(CodexBrowserAuthError.cancelled))
    }
}

@MainActor
private final class CodexBrowserPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: (@MainActor @Sendable () -> ASPresentationAnchor)?

    init(anchor: (@MainActor @Sendable () -> ASPresentationAnchor)?) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor {
            return anchor()
        }
        #if canImport(UIKit)
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            return window
        }
        #endif
        return ASPresentationAnchor()
    }
}

private final class CodexLoopbackCallbackServer: @unchecked Sendable {
    private let publicHost: String
    private let port: UInt16
    private let path: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "dev.codex.browser-auth")
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didDeliverCallback = false

    init(publicHost: String, port: UInt16, path: String, timeout: Duration) throws {
        self.publicHost = publicHost
        self.port = port
        self.path = path
        self.timeout = timeout
    }

    func start() async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CodexBrowserAuthError.invalidCallbackURL
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }
                switch state {
                case .ready:
                    self.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: self?.timeout ?? .seconds(0))
                        self?.resumeCallback(with: .failure(CodexBrowserAuthError.callbackTimedOut))
                    }
                    self.resumeStart(
                        with: .success("http://\(self.publicHost):\(self.port)\(self.path)")
                    )
                case .failed(let error):
                    self.resumeStart(with: .failure(error))
                    self.resumeCallback(with: .failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let pendingResult: Result<URL, Error>? = withStateLock {
                if let pendingCallbackResult {
                    self.pendingCallbackResult = nil
                    didDeliverCallback = true
                    return pendingCallbackResult
                }
                callbackContinuation = continuation
                return nil
            }

            guard let pendingResult else {
                return
            }
            switch pendingResult {
            case .success(let callbackURL):
                continuation.resume(returning: callbackURL)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        let state = withStateLock { () -> (Task<Void, Never>?, NWListener?) in
            let state = (timeoutTask, listener)
            timeoutTask = nil
            listener = nil
            startContinuation = nil
            callbackContinuation = nil
            pendingCallbackResult = nil
            didDeliverCallback = true
            return state
        }
        state.0?.cancel()
        state.1?.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.resumeCallback(with: .failure(error))
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.processRequestData(nextBuffer, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func processRequestData(_ data: Data, on connection: NWConnection) {
        let requestText = String(decoding: data, as: UTF8.self)
        let requestLine = requestText.components(separatedBy: "\r\n").first ?? ""
        let pathWithQuery = requestLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst()
            .first
            .map(String.init) ?? ""

        guard
            !pathWithQuery.isEmpty,
            let callbackURL = URL(string: "http://\(publicHost):\(port)\(pathWithQuery)"),
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.path == path
        else {
            sendResponse(statusLine: "HTTP/1.1 404 Not Found", body: "Not found", on: connection)
            return
        }

        sendResponse(statusLine: "HTTP/1.1 200 OK", body: "Login complete. You can return to the app.", on: connection)
        resumeCallback(with: .success(callbackURL))
    }

    private func sendResponse(statusLine: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let header = [
            statusLine,
            "Content-Type: text/plain; charset=UTF-8",
            "Connection: close",
            "Content-Length: \(bodyData.count)",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resumeStart(with result: Result<String, Error>) {
        let continuation = withStateLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        switch result {
        case .success(let redirectURI):
            continuation?.resume(returning: redirectURI)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func resumeCallback(with result: Result<URL, Error>) {
        let state = withStateLock { () -> (CheckedContinuation<URL, Error>?, Task<Void, Never>?, NWListener?) in
            guard !didDeliverCallback else {
                return (nil, nil, nil)
            }
            didDeliverCallback = true
            let continuation = callbackContinuation
            callbackContinuation = nil
            if continuation == nil {
                pendingCallbackResult = result
            }
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            let listener = self.listener
            self.listener = nil
            return (continuation, timeoutTask, listener)
        }
        state.1?.cancel()
        state.2?.cancel()
        switch result {
        case .success(let callbackURL):
            state.0?.resume(returning: callbackURL)
        case .failure(let error):
            state.0?.resume(throwing: error)
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
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
