import Foundation

#if canImport(Security)
import Security
#endif

public protocol CodexAPIKeyStore: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

public final class CodexKeychainAPIKeyStore: CodexAPIKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "CodexKit API Key", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func loadAPIKey() throws -> String? {
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
            throw CodexAPIKeyStoreError.keychainStatus(status)
        }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw CodexAPIKeyStoreError.invalidStoredData
        }
        return value
        #else
        return nil
        #endif
    }

    public func saveAPIKey(_ apiKey: String) throws {
        #if canImport(Security)
        let data = Data(apiKey.utf8)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw CodexAPIKeyStoreError.keychainStatus(status)
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexAPIKeyStoreError.keychainStatus(addStatus)
        }
        #endif
    }

    public func deleteAPIKey() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CodexAPIKeyStoreError.keychainStatus(status)
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

public enum CodexAPIKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidStoredData
}
