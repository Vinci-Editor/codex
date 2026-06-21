//
//  CodexSessionToolLoopTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

/// URLProtocol that returns a canned SSE body per model round-trip, letting us
/// drive `CodexSession.runTurn` without a real network. The `responder` decides,
/// for each request index, whether to emit another tool call (continue the loop)
/// or a plain completion (stop the loop).
private final class ToolLoopMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _responder: (@Sendable (Int) -> Data)?

    static func reset(responder: @escaping @Sendable (Int) -> Data) {
        lock.lock()
        _requestCount = 0
        _responder = responder
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    private static func nextBody() -> Data {
        lock.lock(); defer { lock.unlock() }
        let index = _requestCount
        _requestCount += 1
        return _responder?(index) ?? Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.nextBody()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://codex-loop-test.local")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct NoopTool: CodexTool {
    let name = "noop"
    let description = "Does nothing; used to keep the tool loop going."
    var inputSchema: [String: any Sendable] {
        ["type": "object", "properties": [String: any Sendable]()]
    }

    func execute(call: CodexToolCall, context: CodexToolContext) async throws -> CodexToolResult {
        CodexToolResult(output: "ok")
    }
}

private func sseEvent(_ object: String) -> String {
    "data: \(object)\n\n"
}

/// One round-trip that requests the `noop` tool, so the loop continues.
private func toolCallBody(index: Int) -> Data {
    let item = #"{"id":"fc_\#(index)","type":"function_call","call_id":"call_\#(index)","name":"noop","arguments":"{}"}"#
    let done = sseEvent(#"{"type":"response.output_item.done","item":\#(item)}"#)
    let completed = sseEvent(#"{"type":"response.completed","response":{"id":"resp_\#(index)"}}"#)
    return Data((done + completed).utf8)
}

/// One round-trip with no tool calls — a plain completion that ends the turn.
private func finalBody(index: Int) -> Data {
    Data(sseEvent(#"{"type":"response.completed","response":{"id":"resp_\#(index)"}}"#).utf8)
}

private func makeSession(tools: [any CodexTool] = [NoopTool()]) -> CodexSession {
    let provider = CodexProvider.custom(
        id: "loop-test",
        name: "Loop Test",
        baseURL: URL(string: "https://codex-loop-test.local/v1")!,
        authMode: .none
    )
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [ToolLoopMockURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfig)
    let configuration = CodexSessionConfiguration(
        provider: provider,
        model: "loop-test-model",
        tools: tools,
        urlSession: urlSession
    )
    return CodexSession(configuration: configuration)
}

@Suite(.serialized)
struct CodexSessionToolLoopTests {
    /// With no cap (the shipped default), the turn must run past the old hardcoded
    /// limit of 8 round-trips and complete when the model finally stops calling tools.
    @Test
    func unlimitedLoopRunsPastLegacyEightRoundCap() async throws {
        // Tool call for the first 10 rounds, then a plain message on the 11th.
        ToolLoopMockURLProtocol.reset { index in
            index < 10 ? toolCallBody(index: index) : finalBody(index: index)
        }

        let session = makeSession()
        // maxToolIterations: nil => unlimited (matches codex-rs).
        let stream = await session.submit(userText: "go", options: CodexTurnOptions())

        // Should complete without throwing.
        for try await _ in stream {}

        #expect(ToolLoopMockURLProtocol.requestCount == 11)
    }

    /// A finite cap must still throw `toolLoopLimitExceeded`, after exactly that
    /// many model round-trips.
    @Test
    func finiteCapThrowsAfterReachingLimit() async throws {
        // Always request a tool, so only the cap can stop the loop.
        ToolLoopMockURLProtocol.reset { index in toolCallBody(index: index) }

        let session = makeSession()
        let stream = await session.submit(userText: "go", options: CodexTurnOptions(maxToolIterations: 3))

        await #expect(throws: CodexSessionError.toolLoopLimitExceeded) {
            for try await _ in stream {}
        }

        #expect(ToolLoopMockURLProtocol.requestCount == 3)
    }
}
