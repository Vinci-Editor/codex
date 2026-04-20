use std::path::Component;
use std::path::Path;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Workspace {
    root: PathBuf,
    cwd: PathBuf,
}

impl Workspace {
    pub fn new(root: &str, workdir: Option<&str>) -> Result<Self, String> {
        let root = PathBuf::from(root)
            .canonicalize()
            .map_err(|error| format!("workspace root is not accessible: {error}"))?;
        if !root.is_dir() {
            return Err("workspace root is not a directory".to_string());
        }
        let cwd = match workdir {
            Some(workdir) if !workdir.trim().is_empty() => {
                let cwd = Self::lexical_join(&root, Path::new(workdir))?;
                cwd.canonicalize()
                    .map_err(|error| format!("workdir is not accessible: {error}"))?
            }
            _ => root.clone(),
        };
        if !cwd.starts_with(&root) {
            return Err("workdir escapes workspace".to_string());
        }
        Ok(Self { root, cwd })
    }

    pub fn cwd(&self) -> &Path {
        &self.cwd
    }

    pub fn resolve_existing(&self, raw: &str) -> Result<PathBuf, String> {
        let path = self.lexical_path(raw)?;
        let canonical = path
            .canonicalize()
            .map_err(|error| format!("{raw}: {error}"))?;
        self.ensure_inside(&canonical)?;
        Ok(canonical)
    }

    pub fn resolve_for_write(&self, raw: &str) -> Result<PathBuf, String> {
        let path = self.lexical_path(raw)?;
        let parent = path
            .parent()
            .ok_or_else(|| format!("{raw}: missing parent directory"))?;
        let canonical_parent = parent
            .canonicalize()
            .map_err(|error| format!("{raw}: {error}"))?;
        self.ensure_inside(&canonical_parent)?;
        Ok(path)
    }

    pub fn display_path(&self, path: &Path) -> String {
        path.strip_prefix(&self.root)
            .ok()
            .and_then(|path| path.to_str())
            .filter(|path| !path.is_empty())
            .unwrap_or(".")
            .to_string()
    }

    fn lexical_path(&self, raw: &str) -> Result<PathBuf, String> {
        let raw = if raw.trim().is_empty() { "." } else { raw };
        Self::lexical_join(&self.cwd, Path::new(raw))
    }

    fn lexical_join(base: &Path, path: &Path) -> Result<PathBuf, String> {
        let mut joined = if path.is_absolute() {
            PathBuf::new()
        } else {
            base.to_path_buf()
        };
        for component in path.components() {
            match component {
                Component::RootDir => joined.push(Path::new("/")),
                Component::CurDir => {}
                Component::ParentDir => {
                    if !joined.pop() {
                        return Err("path escapes filesystem root".to_string());
                    }
                }
                Component::Normal(value) => joined.push(value),
                Component::Prefix(_) => return Err("unsupported path prefix".to_string()),
            }
        }
        Ok(joined)
    }

    fn ensure_inside(&self, path: &Path) -> Result<(), String> {
        if path.starts_with(&self.root) {
            Ok(())
        } else {
            Err(format!(
                "{} escapes workspace {}",
                path.display(),
                self.root.display()
            ))
        }
    }
}
