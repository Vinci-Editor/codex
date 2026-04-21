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
    public let planType: String?

    public init(
        idToken: String,
        accessToken: String,
        refreshToken: String,
        accountID: String? = nil,
        planType: String? = nil
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.planType = planType
    }

    public var resolvedChatGPTAccountID: String? {
        resolvedAccountMetadata.accountID
    }

    public var resolvedAccountMetadata: CodexAccountMetadata {
        let idClaims = Self.claims(from: idToken)
        let accessClaims = Self.claims(from: accessToken)
        return CodexAccountMetadata(
            accountID: firstNonEmpty(accountID, idClaims.accountID, accessClaims.accountID),
            userID: firstNonEmpty(idClaims.userID, accessClaims.userID),
            email: firstNonEmpty(idClaims.email, accessClaims.email),
            planType: firstNonEmpty(planType, idClaims.planType, accessClaims.planType),
            isFedRAMP: idClaims.isFedRAMP || accessClaims.isFedRAMP
        )
    }

    public var accessTokenExpiresAt: Date? {
        guard let expiresAt = Self.claims(from: accessToken).expiresAt else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }

    public func shouldRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt = accessTokenExpiresAt else {
            return false
        }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    public static func chatGPTAccountID(from idToken: String) -> String? {
        claims(from: idToken).accountID
    }

    public static func accountMetadata(idToken: String, accessToken: String? = nil) -> CodexAccountMetadata {
        let idClaims = claims(from: idToken)
        let accessClaims = accessToken.map(claims(from:)) ?? ParsedClaims()
        return CodexAccountMetadata(
            accountID: firstNonEmpty(idClaims.accountID, accessClaims.accountID),
            userID: firstNonEmpty(idClaims.userID, accessClaims.userID),
            email: firstNonEmpty(idClaims.email, accessClaims.email),
            planType: firstNonEmpty(idClaims.planType, accessClaims.planType),
            isFedRAMP: idClaims.isFedRAMP || accessClaims.isFedRAMP
        )
    }

    private static func claims(from token: String) -> ParsedClaims {
        guard let claims = try? CodexMobileCoreBridge.parseChatGPTTokenClaims(token: token) else {
            return ParsedClaims()
        }
        return ParsedClaims(
            accountID: string(claims["chatgptAccountId"]),
            userID: string(claims["chatgptUserId"]),
            email: string(claims["email"]),
            planType: string(claims["chatgptPlanType"]),
            isFedRAMP: claims["chatgptAccountIsFedramp"] as? Bool ?? false,
            expiresAt: int64(claims["expiresAt"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as Double:
            return Int64(value)
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }
}

public struct CodexAccountMetadata: Sendable, Equatable, Codable {
    public let accountID: String?
    public let userID: String?
    public let email: String?
    public let planType: String?
    public let isFedRAMP: Bool

    public init(
        accountID: String? = nil,
        userID: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        isFedRAMP: Bool = false
    ) {
        self.accountID = accountID
        self.userID = userID
        self.email = email
        self.planType = planType
        self.isFedRAMP = isFedRAMP
    }
}

private struct ParsedClaims {
    let accountID: String?
    let userID: String?
    let email: String?
    let planType: String?
    let isFedRAMP: Bool
    let expiresAt: Int64?

    init(
        accountID: String? = nil,
        userID: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        isFedRAMP: Bool = false,
        expiresAt: Int64? = nil
    ) {
        self.accountID = accountID
        self.userID = userID
        self.email = email
        self.planType = planType
        self.isFedRAMP = isFedRAMP
        self.expiresAt = expiresAt
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.compactMap { value in
        value?.isEmpty == false ? value : nil
    }.first
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
