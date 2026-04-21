import CodexMobileCoreBridge
import Foundation

public enum CodexDeviceKeyProtectionPolicy: String, Sendable {
    case hardwareOnly = "hardware_only"
    case allowOSProtectedNonextractable = "allow_os_protected_nonextractable"
}

public enum CodexDeviceKeyProtectionClass: String, Sendable {
    case hardwareSecureEnclave = "hardware_secure_enclave"
    case hardwareTPM = "hardware_tpm"
    case osProtectedNonextractable = "os_protected_nonextractable"
}

public enum CodexDeviceKeyAlgorithm: String, Sendable {
    case ecdsaP256SHA256 = "ecdsa_p256_sha256"
}

public enum CodexDeviceKeySignPayload: Sendable, Equatable {
    case remoteControlClientConnection(RemoteControlClientConnection)
    case remoteControlClientEnrollment(RemoteControlClientEnrollment)

    public func signingPayloadBytes() throws -> Data {
        try CodexMobileCoreBridge.deviceKeySigningPayload(jsonObject)
    }

    public var jsonObject: [String: Any] {
        switch self {
        case .remoteControlClientConnection(let payload):
            return payload.jsonObject
        case .remoteControlClientEnrollment(let payload):
            return payload.jsonObject
        }
    }

    public struct RemoteControlClientConnection: Sendable, Equatable {
        public var nonce: String
        public var sessionID: String
        public var targetOrigin: String
        public var targetPath: String
        public var accountUserID: String
        public var clientID: String
        public var tokenExpiresAt: Int64
        public var tokenSHA256Base64URL: String
        public var scopes: [String]

        public init(
            nonce: String,
            sessionID: String,
            targetOrigin: String,
            targetPath: String,
            accountUserID: String,
            clientID: String,
            tokenExpiresAt: Int64,
            tokenSHA256Base64URL: String,
            scopes: [String] = ["remote_control_controller_websocket"]
        ) {
            self.nonce = nonce
            self.sessionID = sessionID
            self.targetOrigin = targetOrigin
            self.targetPath = targetPath
            self.accountUserID = accountUserID
            self.clientID = clientID
            self.tokenExpiresAt = tokenExpiresAt
            self.tokenSHA256Base64URL = tokenSHA256Base64URL
            self.scopes = scopes
        }

        var jsonObject: [String: Any] {
            [
                "type": "remoteControlClientConnection",
                "nonce": nonce,
                "audience": "remote_control_client_websocket",
                "sessionId": sessionID,
                "targetOrigin": targetOrigin,
                "targetPath": targetPath,
                "accountUserId": accountUserID,
                "clientId": clientID,
                "tokenExpiresAt": tokenExpiresAt,
                "tokenSha256Base64url": tokenSHA256Base64URL,
                "scopes": scopes,
            ]
        }
    }

    public struct RemoteControlClientEnrollment: Sendable, Equatable {
        public var nonce: String
        public var challengeID: String
        public var targetOrigin: String
        public var targetPath: String
        public var accountUserID: String
        public var clientID: String
        public var deviceIdentitySHA256Base64URL: String
        public var challengeExpiresAt: Int64

        public init(
            nonce: String,
            challengeID: String,
            targetOrigin: String,
            targetPath: String,
            accountUserID: String,
            clientID: String,
            deviceIdentitySHA256Base64URL: String,
            challengeExpiresAt: Int64
        ) {
            self.nonce = nonce
            self.challengeID = challengeID
            self.targetOrigin = targetOrigin
            self.targetPath = targetPath
            self.accountUserID = accountUserID
            self.clientID = clientID
            self.deviceIdentitySHA256Base64URL = deviceIdentitySHA256Base64URL
            self.challengeExpiresAt = challengeExpiresAt
        }

        var jsonObject: [String: Any] {
            [
                "type": "remoteControlClientEnrollment",
                "nonce": nonce,
                "audience": "remote_control_client_enrollment",
                "challengeId": challengeID,
                "targetOrigin": targetOrigin,
                "targetPath": targetPath,
                "accountUserId": accountUserID,
                "clientId": clientID,
                "deviceIdentitySha256Base64url": deviceIdentitySHA256Base64URL,
                "challengeExpiresAt": challengeExpiresAt,
            ]
        }
    }
}
