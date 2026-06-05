//
//  Created by Ethan Lipnik
//

import CryptoKit
import Foundation

#if canImport(Security)
import Security
#endif

extension CodexBrowserAuthenticator {
    internal static func generatePKCECodeVerifier() -> String {
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

    internal static func generatePKCECodeChallenge(_ codeVerifier: String) -> String {
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
