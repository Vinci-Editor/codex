use serde::Deserialize;
use serde_json::Value;
use serde_json::json;

pub fn builtin_tools_json() -> String {
    json!({
        "tools": [
            list_dir_tool(),
            apply_patch_tool(),
            shell_command_tool(),
            exec_command_tool(),
        ]
    })
    .to_string()
}

fn list_dir_tool() -> Value {
    json!({
        "type": "function",
        "name": "list_dir",
        "description": "Lists entries in a workspace directory with simple type labels.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "dir_path": {
                    "type": "string",
                    "description": "Path to the directory to list, relative to the workspace unless absolute."
                },
                "offset": { "type": "number" },
                "limit": { "type": "number" },
                "depth": { "type": "number" }
            },
            "required": ["dir_path"],
            "additionalProperties": false
        }
    })
}

fn apply_patch_tool() -> Value {
    json!({
        "type": "function",
        "name": "apply_patch",
        "description": "Applies a Codex apply_patch patch inside the active workspace.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "patch": {
                    "type": "string",
                    "description": "Patch text using the *** Begin Patch / *** End Patch grammar."
                },
                "workdir": {
                    "type": "string",
                    "description": "Optional working directory relative to the workspace."
                }
            },
            "required": ["patch"],
            "additionalProperties": false
        }
    })
}

fn shell_command_tool() -> Value {
    json!({
        "type": "function",
        "name": "shell_command",
        "description": "Runs a shell-like command. On iOS this is a deterministic Codex emulator, not arbitrary process execution. On macOS CodexKit may route to a Process-backed shell backend.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "command": { "type": "string" },
                "workdir": { "type": "string" },
                "timeout_ms": { "type": "number" }
            },
            "required": ["command"],
            "additionalProperties": false
        }
    })
}

fn exec_command_tool() -> Value {
    json!({
        "type": "function",
        "name": "exec_command",
        "description": "Runs a shell-like command and returns Codex unified exec output. On iOS this uses the same deterministic emulator as shell_command.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "cmd": { "type": "string", "description": "Shell command to execute." },
                "workdir": { "type": "string" },
                "yield_time_ms": { "type": "number" },
                "max_output_tokens": { "type": "number" }
            },
            "required": ["cmd"],
            "additionalProperties": false
        }
    })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToolOutputInput {
    call_id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    output: Value,
    #[serde(default = "default_success")]
    success: bool,
    #[serde(default)]
    custom: bool,
}

fn default_success() -> bool {
    true
}

pub fn tool_output_json(input: &str) -> Result<String, serde_json::Error> {
    let input: ToolOutputInput = serde_json::from_str(input)?;
    let output = normalize_tool_output(input.output, input.success);
    let item = if input.custom {
        json!({
            "type": "custom_tool_call_output",
            "call_id": input.call_id,
            "name": input.name,
            "output": output,
        })
    } else {
        json!({
            "type": "function_call_output",
            "call_id": input.call_id,
            "output": output,
        })
    };
    serde_json::to_string(&item)
}

fn normalize_tool_output(output: Value, success: bool) -> String {
    let text = match output {
        Value::String(text) => text,
        value => value.to_string(),
    };
    if success {
        text
    } else {
        format!("Tool failed:\n{text}")
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn builds_custom_tool_call_output() {
        let json = tool_output_json(
            r#"{"callId":"call-1","name":"custom","output":"done","success":true,"custom":true}"#,
        )
        .expect("tool output");
        let value: Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["type"], "custom_tool_call_output");
        assert_eq!(value["call_id"], "call-1");
        assert_eq!(value["name"], "custom");
        assert_eq!(value["output"], "done");
    }
}
