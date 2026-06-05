//
//  CodexWorkspaceToolTests.swift
//  CodexKitTests
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge

@Test
func workspaceStoreRoundTripsSecurityScopedWorkspaceRecord() throws {
    let suiteName = "CodexWorkspaceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let workspace = CodexWorkspace(rootURL: root, bookmarkData: Data([1, 2, 3]), readOnly: true)
    let store = CodexWorkspaceStore(defaults: defaults)

    let record = try store.save(workspace, displayName: "Demo")
    let resolved = try store.resolve(record)

    #expect(try store.list() == [record])
    #expect(resolved.rootURL.path == root.path)
    #expect(resolved.bookmarkData == Data([1, 2, 3]))
    #expect(resolved.readOnly == true)
}


@Test
func sessionExecutesBuiltinWorkspaceTools() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root),
        toolApprovalHandler: { _ in .approve }
    ))
    let listData = try await session.executeToolCall(CodexToolCall(
        callID: "call-list",
        name: "list_dir",
        arguments: #"{"dir_path":"."}"#
    ))
    let listOutput = try toolOutputBody(listData)

    let readData = try await session.executeToolCall(CodexToolCall(
        callID: "call-read",
        name: "read_file",
        arguments: #"{"path":"notes.txt"}"#
    ))
    let readOutput = try toolOutputBody(readData)

    let searchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-search",
        name: "search_files",
        arguments: #"{"query":"hello","path":"."}"#
    ))
    let searchOutput = try toolOutputBody(searchData)

    let catData = try await session.executeToolCall(CodexToolCall(
        callID: "call-cat",
        name: "shell_command",
        arguments: #"{"command":"cat notes.txt"}"#
    ))
    let catOutput = try toolOutputBody(catData)

    #expect(listOutput.contains("notes.txt"))
    #expect(readOutput == "hello\n")
    #expect(searchOutput.contains("notes.txt:1: hello"))
    #expect(catOutput == "hello\n")

    let patch = """
    *** Begin Patch
    *** Add File: added.txt
    +patched
    *** End Patch
    """
    let patchArguments = try jsonString(["patch": patch])
    let patchData = try await session.executeToolCall(CodexToolCall(
        callID: "call-patch",
        name: "apply_patch",
        arguments: patchArguments
    ))
    let patchOutput = try toolOutputBody(patchData)

    #expect(patchOutput.contains("A added.txt"))
    #expect(try String(contentsOf: root.appending(path: "added.txt"), encoding: .utf8) == "patched\n")

    let writeData = try await session.executeToolCall(CodexToolCall(
        callID: "call-write",
        name: "write_file",
        arguments: try jsonString(["path": "written.txt", "content": "written\n"])
    ))
    let writeOutput = try toolOutputBody(writeData)

    #expect(writeOutput.contains("Wrote written.txt"))
    #expect(try String(contentsOf: root.appending(path: "written.txt"), encoding: .utf8) == "written\n")
}


@Test
func portableShellSupportsAbsoluteUnixCommandEntrypoints() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CodexPortableShell-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try "hello\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    let response = await CodexMobileCoreBridge.emulatePortableShellForTesting([
        "workspaceRoot": root.path,
        "command": #"""
        /bin/cat notes.txt
        /usr/bin/env bash -lc 'printf "%s\n" "$PWD"'
        /usr/bin/env CODEX_TEST_VALUE=portable bash -lc 'printf "%s\n" "$CODEX_TEST_VALUE"'
        sh -c 'printf portable > generated.txt'
        /usr/bin/which cat
        """#,
        "maxOutputBytes": 64 * 1024,
    ])

    #expect(response["exit_code"] as? Int == 0)
    let output = response["output"] as? String ?? ""
    #expect(output.contains("hello\n"))
    #expect(output.contains("/\n"))
    #expect(output.contains("portable\n"))
    #expect(output.contains("/bin/cat\n"))
    #expect(try String(contentsOf: root.appending(path: "generated.txt"), encoding: .utf8) == "portable")
}


@Test
func portableShellSupportsJavaScriptRuntimeEntrypoints() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CodexPortableShellJS-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    try """
    import path from "node:path";
    console.log(path.basename(process.argv[2]));
    """.write(to: root.appending(path: "script.mjs"), atomically: true, encoding: .utf8)

    let response = await CodexMobileCoreBridge.emulatePortableShellForTesting([
        "workspaceRoot": root.path,
        "command": #"""
        js-exec -c 'console.log(1 + 2)'
        node -e 'console.log(require("node:path").join("alpha", "beta"))'
        node -p '21 * 2'
        node --input-type=module -e 'import path from "node:path"; console.log(path.extname("file.swift"))'
        node --input-type=module -e 'import { Workbook } from "@oai/artifact-tool"; const workbook = Workbook.create(); const sheet = workbook.worksheets.add("Smoke"); sheet.getRange("A1").values = [["runtime"]]; console.log(sheet.getRange("A1").values[0][0])'
        node script.mjs /tmp/report.txt
        """#,
        "maxOutputBytes": 64 * 1024,
    ])

    #expect(response["exit_code"] as? Int == 0)
    let output = response["output"] as? String ?? ""
    #expect(output.contains("3\n"))
    #expect(output.contains("alpha/beta\n"))
    #expect(output.contains("42\n"))
    #expect(output.contains(".swift\n"))
    #expect(output.contains("runtime\n"))
    #expect(output.contains("report.txt\n"))
}


@Test
func mutatingBuiltinWorkspaceToolsRequireApproval() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root)
    ))
    let data = try await session.executeToolCall(CodexToolCall(
        callID: "call-write",
        name: "write_file",
        arguments: try jsonString(["path": "denied.txt", "content": "denied\n"])
    ))
    let output = try toolOutputBody(data)

    #expect(output.contains("approval is required"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "denied.txt").path))
}


@Test
func sessionRejectsUnsupportedInteractiveExecArguments() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let session = CodexSession(configuration: CodexSessionConfiguration(
        provider: .lmStudio(),
        model: "local-model",
        workspace: CodexWorkspace(rootURL: root),
        toolApprovalHandler: { _ in .approve }
    ))
    let sessionData = try await session.executeToolCall(CodexToolCall(
        callID: "call-session",
        name: "exec_command",
        arguments: try jsonString(["cmd": "echo hi", "session_id": "proc-1"])
    ))
    let ttyData = try await session.executeToolCall(CodexToolCall(
        callID: "call-tty",
        name: "exec_command",
        arguments: try jsonString(["cmd": "echo hi", "tty": true])
    ))

    #expect(try toolOutputBody(sessionData).contains("one-shot"))
    #expect(try toolOutputBody(sessionData).contains("session_id"))
    #expect(try toolOutputBody(ttyData).contains("TTY"))
}
