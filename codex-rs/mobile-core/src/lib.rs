//! Mobile-safe Codex primitives for Swift bindings.
//!
//! This crate is intentionally not a dependency of `codex-core`. It is the
//! beginning of the portable surface used by `CodexKit`: request shaping,
//! event decoding, provider defaults, auth payload helpers, built-in tool
//! schemas, and the iOS shell emulator. Host responsibilities such as
//! URLSession, Keychain, UI, and macOS `Process` execution remain in Swift.

mod auth;
mod device_key;
mod ffi;
mod output;
mod patch;
mod providers;
mod responses;
mod shell;
mod tools;

pub use auth::authorization_code_token_request_json;
pub use auth::authorization_url_json;
pub use auth::device_code_request_json;
pub use auth::parse_chatgpt_token_claims_json;
pub use auth::refresh_token_request_json;
pub use device_key::device_key_signing_payload_json;
pub use ffi::CodexMobileBuffer;
pub use patch::apply_patch_json;
pub use providers::provider_defaults_json;
pub use responses::build_responses_request_json;
pub use responses::parse_sse_event_json;
pub use shell::ShellEmulationRequest;
pub use shell::emulate_shell_json;
pub use tools::builtin_tools_json;
pub use tools::tool_output_json;

const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn version_json() -> String {
    serde_json::json!({
        "crate": "codex-mobile-core",
        "version": VERSION,
        "abi": 1,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn exposes_provider_defaults() {
        let json: serde_json::Value =
            serde_json::from_str(&provider_defaults_json()).expect("provider defaults json");
        assert_eq!(json["providers"][0]["id"], "openai");
        assert_eq!(json["providers"][1]["id"], "lmstudio");
    }

    #[test]
    fn exposes_builtin_tool_names() {
        let json: serde_json::Value =
            serde_json::from_str(&builtin_tools_json()).expect("builtin tools json");
        let names = json["tools"]
            .as_array()
            .expect("tools")
            .iter()
            .map(|tool| tool["name"].as_str().expect("name"))
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            vec!["list_dir", "apply_patch", "shell_command", "exec_command"]
        );
    }
}
