use serde::Deserialize;
use serde_json::Value;
use serde_json::json;

pub fn builtin_tools_json() -> String {
    json!({
        "tools": [
            list_dir_tool(),
            apply_patch_tool(),
            view_image_tool(),
            update_plan_tool(),
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

fn view_image_tool() -> Value {
    json!({
        "type": "function",
        "name": "view_image",
        "description": "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Local filesystem path to an image file."
                },
                "detail": {
                    "type": "string",
                    "enum": ["high", "original"],
                    "description": "Image detail level. Defaults to high; use original to preserve exact resolution."
                }
            },
            "required": ["path"],
            "additionalProperties": false
        },
        "output_schema": {
            "type": "object",
            "properties": {
                "image_url": {
                    "type": "string",
                    "description": "Data URL for the loaded image."
                },
                "detail": {
                    "type": "string",
                    "enum": ["high", "original"],
                    "description": "Image detail hint returned by view_image."
                }
            },
            "required": ["image_url", "detail"],
            "additionalProperties": false
        }
    })
}

fn update_plan_tool() -> Value {
    json!({
        "type": "function",
        "name": "update_plan",
        "description": "Updates the task plan.\nProvide an optional explanation and a list of plan items, each with a step and status.\nAt most one step can be in_progress at a time.\n",
        "strict": false,
        "parameters": {
            "type": "object",
            "properties": {
                "explanation": {
                    "type": "string",
                    "description": "Optional explanation for this plan update."
                },
                "plan": {
                    "type": "array",
                    "description": "The list of steps",
                    "items": {
                        "type": "object",
                        "properties": {
                            "step": {
                                "type": "string",
                                "description": "Task step text."
                            },
                            "status": {
                                "type": "string",
                                "enum": ["pending", "in_progress", "completed"],
                                "description": "Step status."
                            }
                        },
                        "required": ["step", "status"],
                        "additionalProperties": false
                    }
                }
            },
            "required": ["plan"],
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

fn normalize_tool_output(output: Value, success: bool) -> Value {
    if success && is_tool_output_content_items(&output) {
        return output;
    }
    let text = match output {
        Value::String(text) => text,
        value => value.to_string(),
    };
    if success {
        Value::String(text)
    } else {
        Value::String(format!("Tool failed:\n{text}"))
    }
}

fn is_tool_output_content_items(output: &Value) -> bool {
    let Some(items) = output.as_array() else {
        return false;
    };
    if items.is_empty() {
        return false;
    }
    items.iter().all(|item| {
        let Some(item) = item.as_object() else {
            return false;
        };
        match item.get("type").and_then(Value::as_str) {
            Some("input_text") => item.get("text").and_then(Value::as_str).is_some(),
            Some("input_image") => item.get("image_url").and_then(Value::as_str).is_some(),
            _ => false,
        }
    })
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

    #[test]
    fn preserves_structured_image_tool_output() {
        let json = tool_output_json(
            r#"{"callId":"call-1","output":[{"type":"input_image","image_url":"data:image/png;base64,AAA","detail":"high"}],"success":true,"custom":false}"#,
        )
        .expect("tool output");
        let value: Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["type"], "function_call_output");
        assert_eq!(value["call_id"], "call-1");
        assert_eq!(value["output"][0]["type"], "input_image");
        assert_eq!(
            value["output"][0]["image_url"],
            "data:image/png;base64,AAA"
        );
    }
}
