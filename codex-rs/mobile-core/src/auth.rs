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
struct AuthorizationUrlInput {
    issuer: String,
    client_id: String,
    redirect_uri: String,
    state: String,
    code_challenge: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthorizationCodeTokenRequestInput {
    client_id: String,
    code: String,
    code_verifier: String,
    redirect_uri: String,
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
    expires_at: Option<i64>,
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

pub fn authorization_url_json(input: &str) -> Result<String, serde_json::Error> {
    let input: AuthorizationUrlInput = serde_json::from_str(input)?;
    let issuer = input.issuer.trim_end_matches('/');
    let query = form_encode(&[
        ("response_type", "code"),
        ("client_id", &input.client_id),
        ("redirect_uri", &input.redirect_uri),
        ("scope", "openid profile email offline_access"),
        ("code_challenge", &input.code_challenge),
        ("code_challenge_method", "S256"),
        ("state", &input.state),
        ("id_token_add_organizations", "true"),
        ("codex_cli_simplified_flow", "true"),
    ]);
    Ok(serde_json::json!({
        "url": format!("{issuer}/oauth/authorize?{query}"),
    })
    .to_string())
}

pub fn authorization_code_token_request_json(input: &str) -> Result<String, serde_json::Error> {
    let input: AuthorizationCodeTokenRequestInput = serde_json::from_str(input)?;
    let body = form_encode(&[
        ("grant_type", "authorization_code"),
        ("code", &input.code),
        ("redirect_uri", &input.redirect_uri),
        ("client_id", &input.client_id),
        ("code_verifier", &input.code_verifier),
    ]);
    Ok(serde_json::json!({
        "path": "/oauth/token",
        "method": "POST",
        "headers": {
            "Content-Type": "application/x-www-form-urlencoded",
        },
        "body": body,
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
            .or_else(|| value.get("chatgpt_plan_type"))
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_user_id: auth
            .and_then(|auth| auth.get("chatgpt_user_id").or_else(|| auth.get("user_id")))
            .or_else(|| {
                value
                    .get("chatgpt_user_id")
                    .or_else(|| value.get("user_id"))
            })
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_account_id: auth
            .and_then(|auth| auth.get("chatgpt_account_id"))
            .or_else(|| {
                value
                    .get("chatgpt_account_id")
                    .or_else(|| value.get("organization_id"))
            })
            .and_then(Value::as_str)
            .map(str::to_string),
        chatgpt_account_is_fedramp: auth
            .and_then(|auth| auth.get("chatgpt_account_is_fedramp"))
            .or_else(|| value.get("chatgpt_account_is_fedramp"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        expires_at: value.get("exp").and_then(Value::as_i64),
    })
}

fn form_encode(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(key, value)| format!("{}={}", percent_encode(key), percent_encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                encoded.push(byte as char);
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
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

    #[test]
    fn builds_browser_authorize_url() {
        let json = authorization_url_json(
            r#"{"issuer":"https://auth.openai.com","clientId":"client","redirectUri":"http://localhost:1455/auth/callback","state":"state","codeChallenge":"challenge"}"#,
        )
        .expect("authorize url");
        let value: Value = serde_json::from_str(&json).expect("json");
        let url = value["url"].as_str().expect("url");

        assert!(url.starts_with("https://auth.openai.com/oauth/authorize?"));
        assert!(url.contains("client_id=client"));
        assert!(url.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"));
        assert!(url.contains("code_challenge=challenge"));
    }

    #[test]
    fn builds_authorization_code_token_payload() {
        let json = authorization_code_token_request_json(
            r#"{"clientId":"client","code":"code","codeVerifier":"verifier","redirectUri":"http://localhost:1455/auth/callback"}"#,
        )
        .expect("token json");
        let value: Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["path"], "/oauth/token");
        assert_eq!(
            value["headers"]["Content-Type"],
            "application/x-www-form-urlencoded"
        );
        assert_eq!(
            value["body"],
            "grant_type=authorization_code&code=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=client&code_verifier=verifier"
        );
    }
}
