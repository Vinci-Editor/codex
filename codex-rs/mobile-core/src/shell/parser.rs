#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SequenceOp {
    Always,
    And,
    Or,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCommand {
    pub argv: Vec<String>,
    pub stdin_path: Option<String>,
    pub stdout_path: Option<String>,
    pub append_stdout: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedPipeline {
    pub commands: Vec<ParsedCommand>,
    pub next_op: SequenceOp,
}

pub fn parse_script(script: &str) -> Result<Vec<ParsedPipeline>, String> {
    let mut pipelines = Vec::new();
    for (segment, op) in split_sequence(script)? {
        let trimmed = segment.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut commands = Vec::new();
        for command in split_top_level(trimmed, '|')? {
            let command = parse_command(&command)?;
            if !command.argv.is_empty() {
                commands.push(command);
            }
        }
        if !commands.is_empty() {
            pipelines.push(ParsedPipeline {
                commands,
                next_op: op,
            });
        }
    }
    Ok(pipelines)
}

fn parse_command(command: &str) -> Result<ParsedCommand, String> {
    let tokens = tokenize(command)?;
    let mut argv = Vec::new();
    let mut stdin_path = None;
    let mut stdout_path = None;
    let mut append_stdout = false;
    let mut index = 0;

    while index < tokens.len() {
        match tokens[index].as_str() {
            "<" => {
                index += 1;
                stdin_path = Some(
                    tokens
                        .get(index)
                        .ok_or_else(|| "missing path after <".to_string())?
                        .clone(),
                );
            }
            ">" | ">>" => {
                append_stdout = tokens[index] == ">>";
                index += 1;
                stdout_path = Some(
                    tokens
                        .get(index)
                        .ok_or_else(|| "missing path after redirection".to_string())?
                        .clone(),
                );
            }
            token => argv.push(token.to_string()),
        }
        index += 1;
    }

    Ok(ParsedCommand {
        argv,
        stdin_path,
        stdout_path,
        append_stdout,
    })
}

fn split_sequence(script: &str) -> Result<Vec<(String, SequenceOp)>, String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let chars = script.chars().collect::<Vec<_>>();
    let mut index = 0;
    let mut quote = Quote::None;

    while index < chars.len() {
        let ch = chars[index];
        quote = quote.update(ch);
        if quote == Quote::None {
            if ch == ';' {
                result.push((std::mem::take(&mut current), SequenceOp::Always));
                index += 1;
                continue;
            }
            if ch == '&' && chars.get(index + 1) == Some(&'&') {
                result.push((std::mem::take(&mut current), SequenceOp::And));
                index += 2;
                continue;
            }
            if ch == '|' && chars.get(index + 1) == Some(&'|') {
                result.push((std::mem::take(&mut current), SequenceOp::Or));
                index += 2;
                continue;
            }
            if ch == '&' {
                return Err("unsupported shell feature: background jobs".to_string());
            }
        }
        current.push(ch);
        index += 1;
    }

    if quote != Quote::None {
        return Err("unterminated shell quote".to_string());
    }
    result.push((current, SequenceOp::Always));
    Ok(result)
}

fn split_top_level(script: &str, delimiter: char) -> Result<Vec<String>, String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut quote = Quote::None;

    for ch in script.chars() {
        quote = quote.update(ch);
        if quote == Quote::None && ch == delimiter {
            parts.push(std::mem::take(&mut current));
        } else {
            current.push(ch);
        }
    }
    if quote != Quote::None {
        return Err("unterminated shell quote".to_string());
    }
    parts.push(current);
    Ok(parts)
}

fn tokenize(command: &str) -> Result<Vec<String>, String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let chars = command.chars().collect::<Vec<_>>();
    let mut index = 0;
    let mut quote = Quote::None;

    while index < chars.len() {
        let ch = chars[index];
        match quote {
            Quote::None if ch.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            Quote::None if ch == '\'' => quote = Quote::Single,
            Quote::None if ch == '"' => quote = Quote::Double,
            Quote::Single if ch == '\'' => quote = Quote::None,
            Quote::Double if ch == '"' => quote = Quote::None,
            Quote::None if matches!(ch, '<' | '>') => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
                if ch == '>' && chars.get(index + 1) == Some(&'>') {
                    tokens.push(">>".to_string());
                    index += 1;
                } else {
                    tokens.push(ch.to_string());
                }
            }
            _ => current.push(ch),
        }
        index += 1;
    }

    if quote != Quote::None {
        return Err("unterminated shell quote".to_string());
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    Ok(tokens)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Quote {
    None,
    Single,
    Double,
}

impl Quote {
    fn update(self, ch: char) -> Self {
        match (self, ch) {
            (Quote::None, '\'') => Quote::Single,
            (Quote::None, '"') => Quote::Double,
            (Quote::Single, '\'') | (Quote::Double, '"') => Quote::None,
            _ => self,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parses_pipeline_and_sequence() {
        let parsed = parse_script("cat a | grep x && echo ok").expect("parse");

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].commands[0].argv, vec!["cat", "a"]);
        assert_eq!(parsed[0].commands[1].argv, vec!["grep", "x"]);
        assert_eq!(parsed[0].next_op, SequenceOp::And);
    }

    #[test]
    fn parses_redirection() {
        let parsed = parse_script("grep hi < in.txt >> out.txt").expect("parse");
        let command = &parsed[0].commands[0];

        assert_eq!(command.stdin_path.as_deref(), Some("in.txt"));
        assert_eq!(command.stdout_path.as_deref(), Some("out.txt"));
        assert_eq!(command.append_stdout, true);
    }
}
