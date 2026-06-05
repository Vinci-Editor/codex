//
//  Created by Ethan Lipnik
//

import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(CodexMobileCore)
import CodexMobileCore
#endif
#if canImport(JustBash) && canImport(JustBashFS)
import JustBash
import JustBashCommands
import JustBashFS
#endif
#if canImport(JustBashJavaScript)
import JustBashJavaScript
#endif

extension CodexMobileCoreBridge {
    static func fallbackApplyPatch(_ input: [String: Any]) -> [String: Any] {
        [
            "exit_code": 127,
            "stdout": "",
            "stderr": "apply_patch unavailable without CodexMobileCore artifact\n",
            "output": "apply_patch unavailable without CodexMobileCore artifact\n",
            "wall_time_seconds": 0,
            "truncated": false,
        ]
    }

    static func fallbackRefreshTokenRequest(clientID: String, refreshToken: String) -> [String: Any] {
        [
            "path": "/oauth/token",
            "method": "POST",
            "headers": ["Content-Type": "application/json"],
            "body": [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ],
        ]
    }

    static func fallbackAuthorizationURL(_ input: [String: Any]) -> [String: Any] {
        let issuer = (input["issuer"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: input["clientId"] as? String),
            URLQueryItem(name: "redirect_uri", value: input["redirectUri"] as? String),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: input["codeChallenge"] as? String),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: input["state"] as? String),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]
        return ["url": components?.url?.absoluteString ?? ""]
    }

    static func fallbackAuthorizationCodeTokenRequest(_ input: [String: Any]) -> [String: Any] {
        let body = formEncoded([
            ("grant_type", "authorization_code"),
            ("code", input["code"] as? String),
            ("redirect_uri", input["redirectUri"] as? String),
            ("client_id", input["clientId"] as? String),
            ("code_verifier", input["codeVerifier"] as? String),
        ])
        return [
            "path": "/oauth/token",
            "method": "POST",
            "headers": ["Content-Type": "application/x-www-form-urlencoded"],
            "body": body,
        ]
    }

    static func formEncoded(_ pairs: [(String, String?)]) -> String {
        pairs.map { key, value in
            "\(formPercentEncoded(key))=\(formPercentEncoded(value ?? ""))"
        }
        .joined(separator: "&")
    }

    static func formPercentEncoded(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var encoded = ""
        for byte in value.utf8 {
            if allowed.contains(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func fallbackParseChatGPTTokenClaims(token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw CodexMobileCoreBridgeError.invalidJWT
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: payload) else {
            throw CodexMobileCoreBridgeError.invalidJWT
        }
        let value = try decodeObject(data)
        let auth = value["https://api.openai.com/auth"] as? [String: Any]
        let profile = value["https://api.openai.com/profile"] as? [String: Any]
        let email = value["email"] as? String ?? profile?["email"] as? String
        let planType = auth?["chatgpt_plan_type"] as? String ?? value["chatgpt_plan_type"] as? String
        let userID = auth?["chatgpt_user_id"] as? String ?? auth?["user_id"] as? String ?? value["chatgpt_user_id"] as? String ?? value["user_id"] as? String
        let accountID = auth?["chatgpt_account_id"] as? String ?? value["chatgpt_account_id"] as? String ?? value["organization_id"] as? String
        return [
            "email": email ?? NSNull(),
            "chatgptPlanType": planType ?? NSNull(),
            "chatgptUserId": userID ?? NSNull(),
            "chatgptAccountId": accountID ?? NSNull(),
            "chatgptAccountIsFedramp": auth?["chatgpt_account_is_fedramp"] as? Bool ?? value["chatgpt_account_is_fedramp"] as? Bool ?? false,
            "expiresAt": value["exp"] ?? NSNull(),
        ]
    }

    static func fallbackDeviceKeySigningPayload(_ payload: [String: Any]) throws -> Data {
        let signedPayload: [String: Any] = [
            "domain": "codex-device-key-sign-payload/v1",
            "payload": payload,
        ]
        if #available(iOS 13.0, macOS 10.15, *) {
            return try JSONSerialization.data(
                withJSONObject: signedPayload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        return try JSONSerialization.data(withJSONObject: signedPayload, options: [.sortedKeys])
    }
}
