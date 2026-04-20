use super::parser::ParsedCommand;
use super::workspace::Workspace;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl CommandResult {
    pub fn success(stdout: String) -> Self {
        Self {
            exit_code: 0,
            stdout,
            stderr: String::new(),
        }
    }

    pub fn failure(exit_code: i32, stderr: &str) -> Self {
        Self {
            exit_code,
            stdout: String::new(),
            stderr: stderr.to_string(),
        }
    }
}

pub struct CommandRunner {
    workspace: Workspace,
}

impl CommandRunner {
    pub fn new(workspace: Workspace) -> Self {
        Self { workspace }
    }

    pub fn run_pipeline(&self, commands: &[ParsedCommand]) -> CommandResult {
        let mut input = String::new();
        let mut last = CommandResult::success(String::new());

        for command in commands {
            let mut command_input = input.clone();
            if let Some(path) = command.stdin_path.as_deref() {
                match self.read_file(path) {
                    Ok(contents) => command_input = contents,
                    Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
                }
            }

            last = self.run_command(command, &command_input);
            if last.exit_code != 0 {
                return last;
            }
            input = last.stdout.clone();
        }

        if let Some(path) = commands
            .last()
            .and_then(|command| command.stdout_path.as_deref())
            && let Err(error) = self.write_file(
                path,
                &last.stdout,
                commands.last().is_some_and(|c| c.append_stdout),
            )
        {
            return CommandResult::failure(1, &format!("{error}\n"));
        }
        last
    }

    fn run_command(&self, command: &ParsedCommand, stdin: &str) -> CommandResult {
        let Some(name) = command.argv.first().map(String::as_str) else {
            return CommandResult::success(stdin.to_string());
        };
        match name {
            "pwd" => CommandResult::success(format!(
                "{}\n",
                self.workspace.display_path(self.workspace.cwd())
            )),
            "echo" => CommandResult::success(format!("{}\n", command.argv[1..].join(" "))),
            "printf" => self.printf(&command.argv[1..]),
            "ls" => self.ls(&command.argv[1..]),
            "find" => self.find(&command.argv[1..]),
            "cat" => self.cat(&command.argv[1..], stdin),
            "head" => self.head_tail(&command.argv[1..], stdin, true),
            "tail" => self.head_tail(&command.argv[1..], stdin, false),
            "wc" => self.wc(&command.argv[1..], stdin),
            "grep" | "egrep" | "fgrep" | "rg" => self.grep(name, &command.argv[1..], stdin),
            "sort" => self.sort(stdin),
            "uniq" => self.uniq(stdin),
            "sed" => self.sed(&command.argv[1..], stdin),
            "mkdir" => self.mkdir(&command.argv[1..]),
            "touch" => self.touch(&command.argv[1..]),
            "cp" => self.copy_move(&command.argv[1..], false),
            "mv" => self.copy_move(&command.argv[1..], true),
            "rm" => self.rm(&command.argv[1..]),
            "git" => self.git(&command.argv[1..], stdin),
            other => CommandResult::failure(
                127,
                &format!("{other}: unsupported command in Codex iOS shell emulator\n"),
            ),
        }
    }

    fn read_file(&self, raw: &str) -> Result<String, String> {
        let path = self.workspace.resolve_existing(raw)?;
        fs::read_to_string(&path).map_err(|error| format!("{}: {error}", path.display()))
    }

    fn write_file(&self, raw: &str, contents: &str, append: bool) -> Result<(), String> {
        let path = self.workspace.resolve_for_write(raw)?;
        let mut options = fs::OpenOptions::new();
        options.create(true).write(true);
        if append {
            options.append(true);
        } else {
            options.truncate(true);
        }
        std::io::Write::write_all(
            &mut options
                .open(&path)
                .map_err(|error| format!("{}: {error}", path.display()))?,
            contents.as_bytes(),
        )
        .map_err(|error| format!("{}: {error}", path.display()))
    }

    fn ls(&self, args: &[String]) -> CommandResult {
        let path_arg = args
            .iter()
            .find(|arg| !arg.starts_with('-'))
            .map_or(".", String::as_str);
        let path = match self.workspace.resolve_existing(path_arg) {
            Ok(path) => path,
            Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
        };
        if path.is_file() {
            return CommandResult::success(format!("{}\n", self.workspace.display_path(&path)));
        }
        let entries = match fs::read_dir(&path) {
            Ok(entries) => entries,
            Err(error) => {
                return CommandResult::failure(1, &format!("{}: {error}\n", path.display()));
            }
        };
        let mut names = entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect::<Vec<_>>();
        names.sort();
        CommandResult::success(format!("{}\n", names.join("\n")))
    }

    fn printf(&self, args: &[String]) -> CommandResult {
        let Some(format) = args.first() else {
            return CommandResult::success(String::new());
        };
        let mut output = format
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace("\\r", "\r");
        if output.contains("%s") {
            for arg in args.iter().skip(1) {
                output = output.replacen("%s", arg, 1);
            }
        } else if args.len() > 1 {
            output.push_str(&args[1..].join(" "));
        }
        CommandResult::success(output)
    }

    fn find(&self, args: &[String]) -> CommandResult {
        let root_arg = args
            .first()
            .filter(|arg| !arg.starts_with('-'))
            .map_or(".", String::as_str);
        let name_pattern = args
            .windows(2)
            .find_map(|pair| (pair[0] == "-name").then_some(pair[1].as_str()));
        let root = match self.workspace.resolve_existing(root_arg) {
            Ok(path) => path,
            Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
        };
        let mut output = Vec::new();
        self.walk(&root, &mut |path| {
            let name_matches = name_pattern.is_none_or(|pattern| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| wildcard_match(pattern, name))
            });
            if name_matches {
                output.push(self.workspace.display_path(path));
            }
        });
        output.sort();
        CommandResult::success(format!("{}\n", output.join("\n")))
    }

    fn cat(&self, args: &[String], stdin: &str) -> CommandResult {
        if args.is_empty() {
            return CommandResult::success(stdin.to_string());
        }
        let mut output = String::new();
        for arg in args {
            match self.read_file(arg) {
                Ok(contents) => output.push_str(&contents),
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            }
        }
        CommandResult::success(output)
    }

    fn head_tail(&self, args: &[String], stdin: &str, head: bool) -> CommandResult {
        let count = parse_count(args).unwrap_or(10);
        let content = match args
            .iter()
            .find(|arg| !arg.starts_with('-') && arg.parse::<usize>().is_err())
        {
            Some(path) => match self.read_file(path) {
                Ok(content) => content,
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            },
            None => stdin.to_string(),
        };
        let lines = content.lines().collect::<Vec<_>>();
        let selected = if head {
            lines.into_iter().take(count).collect::<Vec<_>>()
        } else {
            lines
                .into_iter()
                .rev()
                .take(count)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect()
        };
        CommandResult::success(format!("{}\n", selected.join("\n")))
    }

    fn wc(&self, args: &[String], stdin: &str) -> CommandResult {
        let content = if let Some(path) = args.iter().find(|arg| !arg.starts_with('-')) {
            match self.read_file(path) {
                Ok(content) => content,
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            }
        } else {
            stdin.to_string()
        };
        CommandResult::success(format!(
            "{} {} {}\n",
            content.lines().count(),
            content.split_whitespace().count(),
            content.len()
        ))
    }

    fn grep(&self, name: &str, args: &[String], stdin: &str) -> CommandResult {
        let ignore_case = args
            .iter()
            .any(|arg| arg == "-i" || arg.contains('i') && arg.starts_with('-'));
        let numbered = args
            .iter()
            .any(|arg| arg == "-n" || arg.contains('n') && arg.starts_with('-'));
        let operands = args
            .iter()
            .filter(|arg| !arg.starts_with('-'))
            .collect::<Vec<_>>();
        let Some(pattern) = operands.first() else {
            return CommandResult::failure(2, "grep: missing pattern\n");
        };
        let files = operands.iter().skip(1).copied().collect::<Vec<_>>();
        let mut output = String::new();
        if files.is_empty() && name != "rg" {
            append_grep_matches(&mut output, None, stdin, pattern, ignore_case, numbered);
        } else {
            let roots = if files.is_empty() {
                vec!["."]
            } else {
                files.into_iter().map(String::as_str).collect()
            };
            for root in roots {
                let path = match self.workspace.resolve_existing(root) {
                    Ok(path) => path,
                    Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
                };
                self.walk_files(&path, &mut |path| {
                    if let Ok(contents) = fs::read_to_string(path) {
                        append_grep_matches(
                            &mut output,
                            Some(&self.workspace.display_path(path)),
                            &contents,
                            pattern,
                            ignore_case,
                            numbered,
                        );
                    }
                });
            }
        }
        CommandResult {
            exit_code: if output.is_empty() { 1 } else { 0 },
            stdout: output,
            stderr: String::new(),
        }
    }

    fn sort(&self, stdin: &str) -> CommandResult {
        let mut lines = stdin.lines().collect::<Vec<_>>();
        lines.sort();
        CommandResult::success(format!("{}\n", lines.join("\n")))
    }

    fn uniq(&self, stdin: &str) -> CommandResult {
        let mut previous = None;
        let mut lines = Vec::new();
        for line in stdin.lines() {
            if previous != Some(line) {
                lines.push(line);
                previous = Some(line);
            }
        }
        CommandResult::success(format!("{}\n", lines.join("\n")))
    }

    fn sed(&self, args: &[String], stdin: &str) -> CommandResult {
        if args.len() == 2 && args[0] == "-n" && args[1].ends_with('p') {
            return print_sed_range(&args[1], stdin);
        }
        if let Some(script) = args.first()
            && script.starts_with("s/")
        {
            return substitute_sed(script, stdin);
        }
        CommandResult::failure(
            2,
            "sed: unsupported expression in Codex iOS shell emulator\n",
        )
    }

    fn mkdir(&self, args: &[String]) -> CommandResult {
        for arg in args.iter().filter(|arg| !arg.starts_with('-')) {
            let path = match self.workspace.resolve_for_write(arg) {
                Ok(path) => path,
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            };
            if let Err(error) = fs::create_dir_all(&path) {
                return CommandResult::failure(1, &format!("{}: {error}\n", path.display()));
            }
        }
        CommandResult::success(String::new())
    }

    fn touch(&self, args: &[String]) -> CommandResult {
        for arg in args {
            let path = match self.workspace.resolve_for_write(arg) {
                Ok(path) => path,
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            };
            if let Err(error) = fs::OpenOptions::new().create(true).append(true).open(&path) {
                return CommandResult::failure(1, &format!("{}: {error}\n", path.display()));
            }
        }
        CommandResult::success(String::new())
    }

    fn copy_move(&self, args: &[String], move_file: bool) -> CommandResult {
        if args.len() != 2 {
            return CommandResult::failure(2, "cp/mv: expected source and destination\n");
        }
        let source = match self.workspace.resolve_existing(&args[0]) {
            Ok(path) => path,
            Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
        };
        let dest = match self.workspace.resolve_for_write(&args[1]) {
            Ok(path) => path,
            Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
        };
        let result = if move_file {
            fs::rename(&source, &dest)
        } else {
            fs::copy(&source, &dest).map(|_| ())
        };
        match result {
            Ok(()) => CommandResult::success(String::new()),
            Err(error) => CommandResult::failure(1, &format!("{error}\n")),
        }
    }

    fn rm(&self, args: &[String]) -> CommandResult {
        let recursive = args
            .iter()
            .any(|arg| arg.contains('r') && arg.starts_with('-'));
        for arg in args.iter().filter(|arg| !arg.starts_with('-')) {
            let path = match self.workspace.resolve_existing(arg) {
                Ok(path) => path,
                Err(error) => return CommandResult::failure(1, &format!("{error}\n")),
            };
            let result = if path.is_dir() {
                if recursive {
                    fs::remove_dir_all(&path)
                } else {
                    fs::remove_dir(&path)
                }
            } else {
                fs::remove_file(&path)
            };
            if let Err(error) = result {
                return CommandResult::failure(1, &format!("{}: {error}\n", path.display()));
            }
        }
        CommandResult::success(String::new())
    }

    fn git(&self, args: &[String], stdin: &str) -> CommandResult {
        match args.first().map(String::as_str) {
            Some("status") => CommandResult::success(
                "On branch unknown\nChanges not computed by mobile emulator\n".to_string(),
            ),
            Some("diff") => CommandResult::success(String::new()),
            Some("grep") => self.grep("rg", &args[1..], stdin),
            _ => CommandResult::failure(
                127,
                "git: unsupported subcommand in Codex iOS shell emulator\n",
            ),
        }
    }

    fn walk(&self, root: &Path, visit: &mut impl FnMut(&Path)) {
        visit(root);
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.filter_map(Result::ok) {
                let Ok(file_type) = entry.file_type() else {
                    continue;
                };
                if file_type.is_symlink() {
                    continue;
                }
                let path = entry.path();
                if file_type.is_dir() {
                    self.walk(&path, visit);
                } else {
                    visit(&path);
                }
            }
        }
    }

    fn walk_files(&self, root: &Path, visit: &mut impl FnMut(&Path)) {
        self.walk(root, &mut |path| {
            if path.is_file() {
                visit(path);
            }
        });
    }
}

fn parse_count(args: &[String]) -> Option<usize> {
    args.windows(2)
        .find_map(|pair| (pair[0] == "-n").then(|| pair[1].parse().ok()).flatten())
        .or_else(|| {
            args.iter()
                .find_map(|arg| arg.strip_prefix('-')?.parse().ok())
        })
}

fn append_grep_matches(
    output: &mut String,
    path: Option<&str>,
    content: &str,
    pattern: &str,
    ignore_case: bool,
    numbered: bool,
) {
    let pattern_cmp = if ignore_case {
        pattern.to_lowercase()
    } else {
        pattern.to_string()
    };
    for (index, line) in content.lines().enumerate() {
        let line_cmp = if ignore_case {
            line.to_lowercase()
        } else {
            line.to_string()
        };
        if line_cmp.contains(&pattern_cmp) {
            if let Some(path) = path {
                output.push_str(path);
                output.push(':');
            }
            if numbered {
                output.push_str(&(index + 1).to_string());
                output.push(':');
            }
            output.push_str(line);
            output.push('\n');
        }
    }
}

fn print_sed_range(expression: &str, stdin: &str) -> CommandResult {
    let range = expression.trim_end_matches('p');
    let (start, end) = range
        .split_once(',')
        .map(|(start, end)| (start.parse::<usize>().ok(), end.parse::<usize>().ok()))
        .unwrap_or_else(|| (range.parse::<usize>().ok(), range.parse::<usize>().ok()));
    let (Some(start), Some(end)) = (start, end) else {
        return CommandResult::failure(2, "sed: unsupported print range\n");
    };
    let lines = stdin
        .lines()
        .enumerate()
        .filter_map(|(index, line)| ((index + 1) >= start && (index + 1) <= end).then_some(line))
        .collect::<Vec<_>>();
    CommandResult::success(format!("{}\n", lines.join("\n")))
}

fn substitute_sed(script: &str, stdin: &str) -> CommandResult {
    let parts = script
        .trim_start_matches("s/")
        .split('/')
        .collect::<Vec<_>>();
    if parts.len() < 2 {
        return CommandResult::failure(2, "sed: invalid substitution\n");
    }
    CommandResult::success(stdin.replace(parts[0], parts[1]))
}

fn wildcard_match(pattern: &str, value: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    match pattern.split_once('*') {
        Some((prefix, suffix)) => value.starts_with(prefix) && value.ends_with(suffix),
        None => pattern == value,
    }
}
