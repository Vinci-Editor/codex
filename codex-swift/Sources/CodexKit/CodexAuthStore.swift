import Foundation
import CodexMobileCoreBridge

#if canImport(Security)
import Security
#endif

public struct CodexAuthTokens: Codable, Sendable, Equatable {
    public let idToken: String
    public let accessToken: String
    public let refreshToken: String
    public let accountID: String?

    public init(idToken: String, accessToken: String, refreshToken: String, accountID: String? = nil) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
    }

    public var resolvedChatGPTAccountID: String? {
        if let accountID, !accountID.isEmpty {
            return accountID
        }
        return Self.chatGPTAccountID(from: idToken)
    }

    public static func chatGPTAccountID(from idToken: String) -> String? {
        guard
            let claims = try? CodexMobileCoreBridge.parseChatGPTTokenClaims(token: idToken),
            let accountID = claims["chatgptAccountId"] as? String,
            !accountID.isEmpty
        else {
            return nil
        }
        return accountID
    }
}

public protocol CodexAuthStore: Sendable {
    func loadTokens() throws -> CodexAuthTokens?
    func saveTokens(_ tokens: CodexAuthTokens) throws
    func deleteTokens() throws
}

public final class CodexKeychainAuthStore: CodexAuthStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "CodexKit Auth", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func loadTokens() throws -> CodexAuthTokens? {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CodexAuthStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw CodexAuthStoreError.invalidStoredData
        }
        return try JSONDecoder().decode(CodexAuthTokens.self, from: data)
        #else
        return nil
        #endif
    }

    public func saveTokens(_ tokens: CodexAuthTokens) throws {
        #if canImport(Security)
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw CodexAuthStoreError.keychainStatus(status)
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexAuthStoreError.keychainStatus(addStatus)
        }
        #endif
    }

    public func deleteTokens() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CodexAuthStoreError.keychainStatus(status)
        }
        #endif
    }

    #if canImport(Security)
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}

public enum CodexAuthStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidStoredData
}
