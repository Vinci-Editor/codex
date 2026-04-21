use base64::Engine;
use codex_device_key::DeviceKeySignPayload;
use codex_device_key::device_key_signing_payload_bytes;
use serde::Deserialize;
use serde::Serialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceKeySigningPayloadInput {
    payload: DeviceKeySignPayload,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DeviceKeySigningPayloadOutput {
    signed_payload_base64: String,
    signed_payload_utf8: String,
}

pub fn device_key_signing_payload_json(input: &str) -> Result<String, serde_json::Error> {
    let input: DeviceKeySigningPayloadInput = serde_json::from_str(input)?;
    let signed_payload = device_key_signing_payload_bytes(&input.payload)
        .map_err(|error| serde_json::Error::io(std::io::Error::other(error)))?;
    let signed_payload_base64 = base64::engine::general_purpose::STANDARD.encode(&signed_payload);
    let signed_payload_utf8 = String::from_utf8(signed_payload)
        .map_err(|error| serde_json::Error::io(std::io::Error::other(error)))?;
    serde_json::to_string(&DeviceKeySigningPayloadOutput {
        signed_payload_base64,
        signed_payload_utf8,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use serde_json::Value;

    #[test]
    fn builds_canonical_remote_control_connection_payload() {
        let json = device_key_signing_payload_json(
            r#"{"payload":{"type":"remoteControlClientConnection","nonce":"nonce","audience":"remote_control_client_websocket","sessionId":"session","targetOrigin":"https://chatgpt.com","targetPath":"/api/codex/remote/control/client","accountUserId":"user","clientId":"client","tokenExpiresAt":123,"tokenSha256Base64url":"47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU","scopes":["remote_control_controller_websocket"]}}"#,
        )
        .expect("device key payload json");
        let value: Value = serde_json::from_str(&json).expect("json");

        assert_eq!(
            value["signedPayloadUtf8"],
            r#"{"domain":"codex-device-key-sign-payload/v1","payload":{"accountUserId":"user","audience":"remote_control_client_websocket","clientId":"client","nonce":"nonce","scopes":["remote_control_controller_websocket"],"sessionId":"session","targetOrigin":"https://chatgpt.com","targetPath":"/api/codex/remote/control/client","tokenExpiresAt":123,"tokenSha256Base64url":"47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU","type":"remoteControlClientConnection"}}"#
        );
    }
}
