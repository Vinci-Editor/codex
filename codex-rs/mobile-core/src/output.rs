pub(crate) fn truncate_output(output: &mut String, max_output_bytes: usize) -> bool {
    if output.len() <= max_output_bytes {
        return false;
    }

    let mut boundary = max_output_bytes;
    while !output.is_char_boundary(boundary) {
        boundary -= 1;
    }
    output.truncate(boundary);
    output.push_str("\n[output truncated]\n");
    true
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn truncates_at_char_boundary() {
        let mut output = "éabc".to_string();

        assert!(truncate_output(&mut output, 1));

        assert_eq!(output, "\n[output truncated]\n");
    }
}
