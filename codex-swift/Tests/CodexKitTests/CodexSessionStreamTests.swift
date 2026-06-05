//
//  CodexSessionStreamTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func mobileBridgeNormalizesTextDelta() throws {
    let event = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.output_text.delta","item_id":"msg-1","delta":"hello"}"#.utf8)
    )

    #expect(event["type"] as? String == "outputTextDelta")
    #expect(event["itemId"] as? String == "msg-1")
    #expect(event["delta"] as? String == "hello")
}


@Test
func sessionDecodesReasoningAndToolArgumentDeltas() throws {
    let reasoning = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","delta":"working"}"#.utf8)
    )
    let arguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","output_index":0,"delta":"{\"path\""}"#.utf8)
    )

    #expect(try CodexSession.decodeStreamEvent(reasoning) == .reasoningSummaryDelta(itemID: "rs-1", delta: "working"))
    #expect(try CodexSession.decodeStreamEvent(arguments) == .toolCallInputDelta(
        itemID: "item-1",
        callID: "call-1",
        delta: #"{"path""#
    ))
}


@Test
func mobileBridgeNormalizesBothToolInputDeltaNames() throws {
    let functionArguments = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","call_id":"call-1","delta":"{\""}"#.utf8)
    )
    let toolInput = try CodexMobileCoreBridge.parseSSEEvent(
        Data(#"{"type":"response.tool_call_input.delta","item_id":"item-2","call_id":"call-2","delta":"path"}"#.utf8)
    )

    #expect(functionArguments["type"] as? String == "toolCallInputDelta")
    #expect(functionArguments["callId"] as? String == "call-1")
    #expect(toolInput["type"] as? String == "toolCallInputDelta")
    #expect(toolInput["itemId"] as? String == "item-2")
    #expect(toolInput["callId"] as? String == "call-2")
}


@Test
func sessionDecodesAssistantItemLifecycle() throws {
    let started = try CodexSession.decodeStreamEvent([
        "type": "outputItemAdded",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
        ],
    ])
    let completed = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "msg-1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "output_text", "text": "Hello"],
            ],
        ],
    ])

    #expect(started == .outputItemStarted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant")))
    #expect(completed == .outputItemCompleted(CodexOutputItem(id: "msg-1", kind: .assistantMessage, role: "assistant", text: "Hello")))
}


@Test
func sessionDecodesCompletedTokenUsage() throws {
    let normalized = try CodexMobileCoreBridge.parseSSEEvent(Data("""
    {
      "type": "response.completed",
      "response": {
        "id": "resp-1",
        "usage": {
          "input_tokens": 120,
          "input_tokens_details": { "cached_tokens": 40 },
          "output_tokens": 30,
          "output_tokens_details": { "reasoning_tokens": 12 },
          "total_tokens": 150
        }
      }
    }
    """.utf8))

    guard case .completed(_, let usage) = try CodexSession.decodeStreamEvent(normalized) else {
        Issue.record("Expected completed event")
        return
    }

    #expect(usage == CodexTokenUsage(
        inputTokens: 120,
        cachedInputTokens: 40,
        outputTokens: 30,
        reasoningOutputTokens: 12,
        totalTokens: 150
    ))
}


@Test
func sessionPreservesCustomToolCallKind() throws {
    let event = try CodexSession.decodeStreamEvent([
        "type": "outputItemDone",
        "item": [
            "id": "item-1",
            "type": "custom_tool_call",
            "call_id": "call-1",
            "name": "custom",
            "input": #"{"value":1}"#,
        ],
    ])

    guard case .outputItemCompleted(let item) = event, let call = item.toolCall else {
        Issue.record("Expected completed custom tool item")
        return
    }
    #expect(call.itemID == "item-1")
    #expect(call.kind == .custom)
    #expect(call.arguments == #"{"value":1}"#)
}


@Test
func toolOutputUsesResponsesFunctionCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: false,
        name: nil
    )

    #expect(output["type"] as? String == "function_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["output"] as? String == "done")
}


@Test
func toolOutputUsesResponsesCustomToolCallOutputShape() {
    let output = CodexMobileCoreBridge.toolOutput(
        callID: "call-1",
        output: "done",
        success: true,
        custom: true,
        name: "custom"
    )

    #expect(output["type"] as? String == "custom_tool_call_output")
    #expect(output["call_id"] as? String == "call-1")
    #expect(output["name"] as? String == "custom")
    #expect(output["output"] as? String == "done")
}
