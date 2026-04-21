mod commands;
mod parser;
pub(crate) mod workspace;

use serde::Deserialize;
use serde::Serialize;
use std::time::Instant;

use crate::output::truncate_output;
use commands::CommandRunner;
use parser::SequenceOp;
use parser::parse_script;
use workspace::Workspace;

const MAX_COMMAND_BYTES: usize = 32 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellEmulationRequest {
    pub workspace_root: String,
    #[serde(default)]
    pub workdir: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub cmd: Option<String>,
    #[serde(default)]
    pub max_output_bytes: Option<usize>,
}

#[derive(Debug, Serialize)]
struct ShellEmulationResponse {
    exit_code: i32,
    stdout: String,
    stderr: String,
    output: String,
    wall_time_seconds: f64,
    truncated: bool,
}

pub fn emulate_shell_json(input: &str) -> Result<String, serde_json::Error> {
    let request: ShellEmulationRequest = serde_json::from_str(input)?;
    let started = Instant::now();
    let response = emulate_shell(request, started);
    serde_json::to_string(&response)
}

fn emulate_shell(request: ShellEmulationRequest, started: Instant) -> ShellEmulationResponse {
    let command = request.command.or(request.cmd).unwrap_or_default();
    let max_output_bytes = request.max_output_bytes.unwrap_or(64 * 1024);
    let result = if command.len() > MAX_COMMAND_BYTES {
        Ok(commands::CommandResult::failure(
            64,
            "command exceeds Codex iOS shell emulator limit of 32768 bytes\n",
        ))
    } else {
        run_script(
            &request.workspace_root,
            request.workdir.as_deref(),
            &command,
        )
    };
    let (exit_code, stdout, stderr) = match result {
        Ok(result) => (result.exit_code, result.stdout, result.stderr),
        Err(error) => (2, String::new(), format!("{error}\n")),
    };
    let mut output = if stderr.is_empty() {
        stdout.clone()
    } else if stdout.is_empty() {
        stderr.clone()
    } else {
        format!("{stdout}{stderr}")
    };
    let truncated = truncate_output(&mut output, max_output_bytes);

    ShellEmulationResponse {
        exit_code,
        stdout,
        stderr,
        output,
        wall_time_seconds: started.elapsed().as_secs_f64(),
        truncated,
    }
}

fn run_script(
    workspace_root: &str,
    workdir: Option<&str>,
    script: &str,
) -> Result<commands::CommandResult, String> {
    if script.contains("$(") || script.contains('`') {
        return Ok(commands::CommandResult::failure(
            127,
            "unsupported shell feature: command substitution\n",
        ));
    }

    let workspace = Workspace::new(workspace_root, workdir)?;
    let runner = CommandRunner::new(workspace);
    let sequence = parse_script(script)?;
    let mut last = commands::CommandResult::success(String::new());
    let mut previous_op = SequenceOp::Always;

    for pipeline in sequence {
        let should_run = match previous_op {
            SequenceOp::Always => true,
            SequenceOp::And => last.exit_code == 0,
            SequenceOp::Or => last.exit_code != 0,
        };
        previous_op = pipeline.next_op;
        if should_run {
            last = runner.run_pipeline(&pipeline.commands);
        }
    }

    Ok(last)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn rejects_command_substitution() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input = serde_json::json!({
            "workspaceRoot": dir.path(),
            "command": "echo $(pwd)",
        });

        let json = emulate_shell_json(&input.to_string()).expect("shell json");
        let value: serde_json::Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["exit_code"], 127);
    }

    #[test]
    fn printf_redirection_creates_file_and_ls_file_reports_it() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input = serde_json::json!({
            "workspaceRoot": dir.path(),
            "command": "printf 'hello\\n' > new_file.txt && ls -l new_file.txt",
        });

        let json = emulate_shell_json(&input.to_string()).expect("shell json");
        let value: serde_json::Value = serde_json::from_str(&json).expect("json");
        let contents = std::fs::read_to_string(dir.path().join("new_file.txt")).expect("file");

        assert_eq!(value["exit_code"], 0);
        assert_eq!(value["stdout"], "new_file.txt\n");
        assert_eq!(contents, "hello\n");
    }

    #[test]
    fn rejects_oversized_command() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input = serde_json::json!({
            "workspaceRoot": dir.path(),
            "command": "x".repeat(32 * 1024 + 1),
        });

        let json = emulate_shell_json(&input.to_string()).expect("shell json");
        let value: serde_json::Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["exit_code"], 64);
        assert_eq!(value["truncated"], false);
    }

    #[test]
    fn truncates_shell_output_at_char_boundary() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input = serde_json::json!({
            "workspaceRoot": dir.path(),
            "command": "printf 'éabc'",
            "maxOutputBytes": 1,
        });

        let json = emulate_shell_json(&input.to_string()).expect("shell json");
        let value: serde_json::Value = serde_json::from_str(&json).expect("json");

        assert_eq!(value["output"], "\n[output truncated]\n");
        assert_eq!(value["truncated"], true);
    }
}
