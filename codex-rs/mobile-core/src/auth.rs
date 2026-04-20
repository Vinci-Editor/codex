use base64::Engine;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceCodeRequestInput {
    client_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshTokenRequestInput {
    client_id: String,
    refresh_token: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TokenClaimsInput {
    token: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ChatGptClaims {
    email: Option<String>,
    chatgpt_plan_type: Option<String>,
    chatgpt_user_id: Option<String>,
    chatgpt_account_id: Option<String>,
    chatgpt_account_is_fedramp: bool,
}

pub fn device_code_request_json(input: &str) -> Result<String, serde_json::Error> {
    let input: DeviceCodeRequestInput = serde_json::from_str(input)?;
    Ok(serde_json::json!({
        "path": "/api/accounts/deviceauth/usercode",
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
        },
        "body": {
            "client_id": input.client_id,
        },
    })
    .to_string())
}

pub fn refresh_token_request_json(input: &str) -> Result<String, serde_json::Error> {
    let input: RefreshTokenRequestInput = serde_json::from_str(input)?;
    Ok(serde_json::json!({
        "path": "/oauth/token",
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
        },
        "body": {
            "client_id": input.client_id,
            "grant_type": "refresh_token",
            "refresh_token": input.refresh_token,
        },
    })
    .to_string())
}

pub fn parse_chatgpt_token_claims_json(input: &str) -> Result<String, serde_json::Error> {
    let input: TokenClaimsInput = serde_json::from_str(input)?;
    let claims = parse_chatgpt_token_claims(&input.token)
        .map_err(|error| serde_json::Error::io(std::io::Error::other(error)))?;
    serde_json::to_string(&claims)
}

fn parse_chatgpt_token_claims(token: &str) -> Result<ChatGptClaims, String> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or_else(|| "token is not a JWT".to_string())?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|error| format!("failed to decode JWT payload: {error}"))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| format!("failed to parse JWT payload: {error}"))?;
    let auth = value
        .get("https://api.openai.com/auth")
        .and_then(Value::as_object);
    let profile = value
        .get("https://api.openai.com/profile")
        .and_then(Value::as_object);

    Ok(ChatGptClaims {
        email: value
            .get("email")
            .and_then(Value::as_str)
            .or_else(|| {
                profile
                    .and_then(|profile| profile.get("email"))
                    .and_then(Value::as_str)
            })
            .map(str::to_string),
        chatgpt_plan_type: auth
            .and_then(|auth| auth.get("chatgpt_plan_type"))
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_user_id: auth
            .and_then(|auth| auth.get("chatgpt_user_id").or_else(|| auth.get("user_id")))
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_account_id: auth
            .and_then(|auth| auth.get("chatgpt_account_id"))
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_account_is_fedramp: auth
            .and_then(|auth| auth.get("chatgpt_account_is_fedramp"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn builds_refresh_payload() {
        let json = refresh_token_request_json(r#"{"clientId":"client","refreshToken":"refresh"}"#)
            .expect("refresh json");
        let value: Value = serde_json::from_str(&json).expect("json");
        assert_eq!(value["body"]["grant_type"], "refresh_token");
        assert_eq!(value["body"]["refresh_token"], "refresh");
    }
}
