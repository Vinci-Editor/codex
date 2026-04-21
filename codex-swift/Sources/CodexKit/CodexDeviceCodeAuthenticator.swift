import Foundation
import CodexMobileCoreBridge

public struct CodexDeviceCode: Codable, Sendable, Equatable {
    public let verificationURL: URL
    public let userCode: String
    public let deviceAuthID: String
    public let interval: TimeInterval
}

public final class CodexDeviceCodeAuthenticator: @unchecked Sendable {
    public static let defaultClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let issuer: URL
    private let clientID: String
    private let session: URLSession

    public init(
        issuer: URL = URL(string: "https://auth.openai.com")!,
        clientID: String = CodexDeviceCodeAuthenticator.defaultClientID,
        session: URLSession = .shared
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.session = session
    }

    public func requestDeviceCode() async throws -> CodexDeviceCode {
        let url = issuer
            .appending(path: "api")
            .appending(path: "accounts")
            .appending(path: "deviceauth")
            .appending(path: "usercode")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UserCodeRequest(clientID: clientID))

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(UserCodeResponse.self, from: data)

        return CodexDeviceCode(
            verificationURL: issuer.appending(path: "codex").appending(path: "device"),
            userCode: decoded.userCode,
            deviceAuthID: decoded.deviceAuthID,
            interval: TimeInterval(decoded.interval)
        )
    }

    public func pollForTokens(deviceCode: CodexDeviceCode) async throws -> CodexAuthTokens {
        let url = issuer
            .appending(path: "api")
            .appending(path: "accounts")
            .appending(path: "deviceauth")
            .appending(path: "token")
        let deadline = Date().addingTimeInterval(15 * 60)

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(TokenPollRequest(
                deviceAuthID: deviceCode.deviceAuthID,
                userCode: deviceCode.userCode
            ))

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let code = try JSONDecoder().decode(CodeSuccessResponse.self, from: data)
                return try await exchangeCodeForTokens(code)
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 404 {
                try await Task.sleep(for: .seconds(max(deviceCode.interval, 1)))
                continue
            }
            try Self.validate(response: response, data: data)
        }

        throw CodexDeviceCodeAuthError.timedOut
    }

    public func refreshTokens(_ tokens: CodexAuthTokens) async throws -> CodexAuthTokens {
        let descriptor = try CodexMobileCoreBridge.refreshTokenRequest(
            clientID: clientID,
            refreshToken: tokens.refreshToken
        )
        let refreshed = try await performTokenRequest(descriptor)
        let refreshToken = refreshed.refreshToken ?? tokens.refreshToken
        let metadata = CodexAuthTokens.accountMetadata(
            idToken: refreshed.idToken,
            accessToken: refreshed.accessToken
        )
        return CodexAuthTokens(
            idToken: refreshed.idToken,
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            accountID: metadata.accountID ?? tokens.resolvedChatGPTAccountID,
            planType: metadata.planType ?? tokens.resolvedAccountMetadata.planType
        )
    }

    private func exchangeCodeForTokens(_ code: CodeSuccessResponse) async throws -> CodexAuthTokens {
        let url = issuer.appending(path: "oauth").appending(path: "token")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code.authorizationCode),
            URLQueryItem(name: "redirect_uri", value: issuer.appending(path: "deviceauth").appending(path: "callback").absoluteString),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: code.codeVerifier),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let tokens = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        guard let refreshToken = tokens.refreshToken else {
            throw CodexDeviceCodeAuthError.missingRefreshToken
        }
        let metadata = CodexAuthTokens.accountMetadata(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken
        )
        return CodexAuthTokens(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            accountID: metadata.accountID,
            planType: metadata.planType
        )
    }

    private func performTokenRequest(_ descriptor: [String: Any]) async throws -> TokenExchangeResponse {
        let path = descriptor["path"] as? String ?? "/oauth/token"
        let url = issuer.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
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
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CodexDeviceCodeAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexDeviceCodeAuthError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}

private struct UserCodeRequest: Encodable {
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct UserCodeResponse: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
        userCode = try container.decode(String.self, forKey: .userCode)
        if let value = try? container.decode(Int.self, forKey: .interval) {
            interval = value
        } else {
            let value = try container.decode(String.self, forKey: .interval)
            guard let interval = Int(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .interval,
                    in: container,
                    debugDescription: "Expected interval to be an Int or integer string."
                )
            }
            self.interval = interval
        }
    }
}

private struct TokenPollRequest: Encodable {
    let deviceAuthID: String
    let userCode: String

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct CodeSuccessResponse: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenExchangeResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

public enum CodexDeviceCodeAuthError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case timedOut
    case missingRefreshToken
}
