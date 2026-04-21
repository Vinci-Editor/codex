use std::path::Path;
use std::time::Instant;

use codex_apply_patch::Hunk;
use codex_utils_absolute_path::AbsolutePathBuf;
use serde::Deserialize;
use serde::Serialize;

use crate::output::truncate_output;
use crate::shell::workspace::Workspace;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyPatchRequest {
    pub workspace_root: String,
    #[serde(default)]
    pub workdir: Option<String>,
    pub patch: String,
    #[serde(default)]
    pub max_output_bytes: Option<usize>,
}

#[derive(Debug, Serialize)]
struct ApplyPatchResponse {
    exit_code: i32,
    stdout: String,
    stderr: String,
    output: String,
    wall_time_seconds: f64,
    truncated: bool,
}

pub fn apply_patch_json(input: &str) -> Result<String, serde_json::Error> {
    let request: ApplyPatchRequest = serde_json::from_str(input)?;
    let started = Instant::now();
    let response = apply_patch_request(request, started);
    serde_json::to_string(&response)
}

fn apply_patch_request(request: ApplyPatchRequest, started: Instant) -> ApplyPatchResponse {
    let max_output_bytes = request.max_output_bytes.unwrap_or(64 * 1024);
    let (exit_code, stdout, stderr) = run_apply_patch(request);
    let mut output = if stderr.is_empty() {
        stdout.clone()
    } else if stdout.is_empty() {
        stderr.clone()
    } else {
        format!("{stdout}{stderr}")
    };
    let truncated = truncate_output(&mut output, max_output_bytes);

    ApplyPatchResponse {
        exit_code,
        stdout,
        stderr,
        output,
        wall_time_seconds: started.elapsed().as_secs_f64(),
        truncated,
    }
}

fn run_apply_patch(request: ApplyPatchRequest) -> (i32, String, String) {
    let workspace = match Workspace::new(&request.workspace_root, request.workdir.as_deref()) {
        Ok(workspace) => workspace,
        Err(error) => return (2, String::new(), format!("{error}\n")),
    };
    if request.patch.trim().is_empty() {
        return (2, String::new(), "patch is empty\n".to_string());
    }

    let cwd = match AbsolutePathBuf::from_absolute_path(workspace.cwd()) {
        Ok(cwd) => cwd,
        Err(error) => return (2, String::new(), format!("invalid workdir: {error}\n")),
    };
    if let Err(error) = ensure_patch_stays_in_workspace(&request.patch, &cwd, workspace.root()) {
        return (1, String::new(), format!("{error}\n"));
    }

    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            return (
                1,
                String::new(),
                format!("build tokio runtime for apply_patch: {error}\n"),
            );
        }
    };

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let fs = codex_exec_server::LOCAL_FS.clone();
    let result = runtime.block_on(codex_apply_patch::apply_patch(
        &request.patch,
        &cwd,
        &mut stdout,
        &mut stderr,
        fs.as_ref(),
        None,
    ));
    let exit_code = match result {
        Ok(()) => 0,
        Err(error) => {
            if stderr.is_empty() {
                stderr = format!("{error}\n").into_bytes();
            }
            1
        }
    };

    (
        exit_code,
        String::from_utf8_lossy(&stdout).to_string(),
        String::from_utf8_lossy(&stderr).to_string(),
    )
}

fn ensure_patch_stays_in_workspace(
    patch: &str,
    cwd: &AbsolutePathBuf,
    workspace_root: &Path,
) -> Result<(), String> {
    let parsed = codex_apply_patch::parse_patch(patch).map_err(|error| error.to_string())?;
    for hunk in parsed.hunks {
        match hunk {
            Hunk::AddFile { path, .. } => ensure_write_path(&path, cwd, workspace_root)?,
            Hunk::DeleteFile { path } => ensure_existing_path(&path, cwd, workspace_root)?,
            Hunk::UpdateFile {
                path, move_path, ..
            } => {
                ensure_existing_path(&path, cwd, workspace_root)?;
                if let Some(move_path) = move_path {
                    ensure_write_path(&move_path, cwd, workspace_root)?;
                }
            }
        }
    }
    Ok(())
}

fn ensure_existing_path(
    raw_path: &Path,
    cwd: &AbsolutePathBuf,
    workspace_root: &Path,
) -> Result<(), String> {
    let path = AbsolutePathBuf::resolve_path_against_base(raw_path, cwd);
    let canonical = path
        .as_path()
        .canonicalize()
        .map_err(|error| format!("{}: {error}", raw_path.display()))?;
    ensure_inside_workspace(&canonical, workspace_root, raw_path)
}

fn ensure_write_path(
    raw_path: &Path,
    cwd: &AbsolutePathBuf,
    workspace_root: &Path,
) -> Result<(), String> {
    let path = AbsolutePathBuf::resolve_path_against_base(raw_path, cwd);
    let parent = path
        .parent()
        .ok_or_else(|| format!("{}: missing parent directory", raw_path.display()))?;
    let canonical_parent = parent
        .canonicalize()
        .map_err(|error| format!("{}: {error}", raw_path.display()))?;
    ensure_inside_workspace(&canonical_parent, workspace_root, raw_path)
}

fn ensure_inside_workspace(
    path: &Path,
    workspace_root: &Path,
    raw_path: &Path,
) -> Result<(), String> {
    if path.starts_with(workspace_root) {
        Ok(())
    } else {
        Err(format!("{} escapes workspace", raw_path.display()))
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;
    use serde_json::json;

    use super::*;

    #[test]
    fn applies_patch_inside_workspace() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input = json!({
            "workspaceRoot": dir.path().display().to_string(),
            "patch": "*** Begin Patch\n*** Add File: hello.txt\n+hello\n*** End Patch\n"
        });

        let response = apply_patch_json(&input.to_string()).expect("response");
        let value: serde_json::Value = serde_json::from_str(&response).expect("json");

        assert_eq!(value["exit_code"], 0);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("hello.txt")).expect("file"),
            "hello\n"
        );
    }

    #[test]
    fn rejects_patch_that_escapes_workspace() {
        let dir = tempfile::tempdir().expect("tempdir");
        let outside = tempfile::tempdir().expect("outside");
        let input = json!({
            "workspaceRoot": dir.path().display().to_string(),
            "patch": format!(
                "*** Begin Patch\n*** Add File: {}/escape.txt\n+bad\n*** End Patch\n",
                outside.path().display()
            )
        });

        let response = apply_patch_json(&input.to_string()).expect("response");
        let value: serde_json::Value = serde_json::from_str(&response).expect("json");

        assert_eq!(value["exit_code"], 1);
        assert_eq!(outside.path().join("escape.txt").exists(), false);
    }
}
