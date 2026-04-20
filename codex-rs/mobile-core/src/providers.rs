use serde::Deserialize;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MobileProvider {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub requires_chatgpt_auth: bool,
    pub supports_responses: bool,
    pub supports_websockets: bool,
}

pub fn provider_defaults() -> Vec<MobileProvider> {
    vec![
        MobileProvider {
            id: "openai".to_string(),
            name: "OpenAI".to_string(),
            base_url: "https://chatgpt.com/backend-api/codex".to_string(),
            requires_chatgpt_auth: true,
            supports_responses: true,
            supports_websockets: false,
        },
        MobileProvider {
            id: "lmstudio".to_string(),
            name: "LM Studio".to_string(),
            base_url: "http://127.0.0.1:1234/v1".to_string(),
            requires_chatgpt_auth: false,
            supports_responses: true,
            supports_websockets: false,
        },
        MobileProvider {
            id: "ollama".to_string(),
            name: "Ollama".to_string(),
            base_url: "http://127.0.0.1:11434/v1".to_string(),
            requires_chatgpt_auth: false,
            supports_responses: true,
            supports_websockets: false,
        },
    ]
}

pub fn provider_defaults_json() -> String {
    serde_json::json!({
        "providers": provider_defaults(),
    })
    .to_string()
}
