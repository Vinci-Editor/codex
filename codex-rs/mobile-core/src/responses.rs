use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildResponsesRequestInput {
    pub model: String,
    #[serde(default)]
    pub instructions: String,
    #[serde(default)]
    pub input: Vec<Value>,
    #[serde(default)]
    pub tools: Vec<Value>,
    #[serde(default = "default_tool_choice")]
    pub tool_choice: String,
    #[serde(default = "default_parallel_tool_calls")]
    pub parallel_tool_calls: bool,
    #[serde(default)]
    pub reasoning: Option<Value>,
    #[serde(default)]
    pub store: bool,
    #[serde(default)]
    pub stream: bool,
    #[serde(default)]
    pub include: Vec<String>,
    #[serde(default)]
    pub service_tier: Option<String>,
    #[serde(default)]
    pub prompt_cache_key: Option<String>,
    #[serde(default)]
    pub text: Option<Value>,
    #[serde(default)]
    pub metadata: Option<Value>,
}

#[derive(Debug, Serialize)]
struct ResponsesRequest<'a> {
    model: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    instructions: &'a str,
    input: &'a [Value],
    tools: &'a [Value],
    tool_choice: &'a str,
    parallel_tool_calls: bool,
    reasoning: Option<&'a Value>,
    store: bool,
    stream: bool,
    include: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    service_tier: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_cache_key: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_metadata: Option<&'a Value>,
}

fn default_tool_choice() -> String {
    "auto".to_string()
}

fn default_parallel_tool_calls() -> bool {
    true
}

pub fn build_responses_request_json(input: &str) -> Result<String, serde_json::Error> {
    let input: BuildResponsesRequestInput = serde_json::from_str(input)?;
    let request = ResponsesRequest {
        model: &input.model,
        instructions: &input.instructions,
        input: &input.input,
        tools: &input.tools,
        tool_choice: &input.tool_choice,
        parallel_tool_calls: input.parallel_tool_calls,
        reasoning: input.reasoning.as_ref(),
        store: input.store,
        stream: input.stream,
        include: &input.include,
        service_tier: input.service_tier.as_deref(),
        prompt_cache_key: input.prompt_cache_key.as_deref(),
        text: input.text.as_ref(),
        client_metadata: input.metadata.as_ref(),
    };
    serde_json::to_string(&request)
}

pub fn parse_sse_event_json(data: &str) -> Result<String, serde_json::Error> {
    let trimmed = data.trim();
    if trimmed == "[DONE]" {
        return Ok(serde_json::json!({ "type": "done" }).to_string());
    }

    let value: Value = serde_json::from_str(trimmed)?;
    let event_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let normalized = match event_type {
        "response.created" => serde_json::json!({
            "type": "created",
            "raw": value,
        }),
        "response.output_text.delta" => serde_json::json!({
            "type": "outputTextDelta",
            "delta": value.get("delta").and_then(Value::as_str).unwrap_or_default(),
            "itemId": value.get("item_id").and_then(Value::as_str),
            "raw": value,
        }),
        "response.reasoning_summary_text.delta" => serde_json::json!({
            "type": "reasoningSummaryDelta",
            "delta": value.get("delta").and_then(Value::as_str).unwrap_or_default(),
            "itemId": value.get("item_id").and_then(Value::as_str),
            "raw": value,
        }),
        "response.function_call_arguments.delta" | "response.tool_call_input.delta" => serde_json::json!({
            "type": "toolCallInputDelta",
            "delta": value.get("delta").and_then(Value::as_str).unwrap_or_default(),
            "itemId": value.get("item_id").and_then(Value::as_str),
            "callId": value.get("call_id").and_then(Value::as_str),
            "outputIndex": value.get("output_index").and_then(Value::as_i64),
            "raw": value,
        }),
        "response.output_item.added" => serde_json::json!({
            "type": "outputItemAdded",
            "item": value.get("item").cloned().unwrap_or(Value::Null),
            "raw": value,
        }),
        "response.output_item.done" => serde_json::json!({
            "type": "outputItemDone",
            "item": value.get("item").cloned().unwrap_or(Value::Null),
            "raw": value,
        }),
        "response.completed" => serde_json::json!({
            "type": "completed",
            "response": value.get("response").cloned().unwrap_or(Value::Null),
            "raw": value,
        }),
        "error" | "response.failed" => serde_json::json!({
            "type": "error",
            "error": value.get("error").cloned().unwrap_or(value.clone()),
            "raw": value,
        }),
        _ => serde_json::json!({
            "type": "raw",
            "eventType": event_type,
            "raw": value,
        }),
    };
    serde_json::to_string(&normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn builds_request_with_tools() {
        let json = build_responses_request_json(
            r#"{"model":"gpt-5","instructions":"hi","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]}],"tools":[{"type":"function","name":"x"}],"stream":true,"toolChoice":"required","parallelToolCalls":false,"serviceTier":"flex","reasoning":{"effort":"low"}}"#,
        )
        .expect("request");
        let value: Value = serde_json::from_str(&json).expect("json");
        assert_eq!(value["model"], "gpt-5");
        assert_eq!(value["input"][0]["content"][1]["type"], "input_image");
        assert_eq!(value["tools"][0]["name"], "x");
        assert_eq!(value["tool_choice"], "required");
        assert_eq!(value["parallel_tool_calls"], false);
        assert_eq!(value["service_tier"], "flex");
        assert_eq!(value["reasoning"]["effort"], "low");
        assert_eq!(value["store"], false);
    }

    #[test]
    fn normalizes_text_delta() {
        let json =
            parse_sse_event_json(r#"{"type":"response.output_text.delta","item_id":"msg-1","delta":"hi"}"#)
            .expect("event");
        let value: Value = serde_json::from_str(&json).expect("json");
        assert_eq!(value["type"], "outputTextDelta");
        assert_eq!(value["itemId"], "msg-1");
        assert_eq!(value["delta"], "hi");
    }

    #[test]
    fn normalizes_reasoning_and_tool_argument_deltas() {
        let reasoning = parse_sse_event_json(
            r#"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","delta":"thinking"}"#,
        )
        .expect("event");
        let reasoning: Value = serde_json::from_str(&reasoning).expect("json");

        let tool = parse_sse_event_json(
            r#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","output_index":0,"delta":"{\""}"#,
        )
        .expect("event");
        let tool: Value = serde_json::from_str(&tool).expect("json");

        let custom_tool = parse_sse_event_json(
            r#"{"type":"response.tool_call_input.delta","item_id":"item-2","call_id":"call-2","delta":"input"}"#,
        )
        .expect("event");
        let custom_tool: Value = serde_json::from_str(&custom_tool).expect("json");

        assert_eq!(reasoning["type"], "reasoningSummaryDelta");
        assert_eq!(reasoning["itemId"], "rs-1");
        assert_eq!(reasoning["delta"], "thinking");
        assert_eq!(tool["type"], "toolCallInputDelta");
        assert_eq!(tool["itemId"], "item-1");
        assert_eq!(tool["callId"], "call-1");
        assert_eq!(tool["outputIndex"], 0);
        assert_eq!(custom_tool["type"], "toolCallInputDelta");
        assert_eq!(custom_tool["callId"], "call-2");
    }
}
