//
//  CodexNativeApplyPatch+Core.swift
//  CodexMobileCoreBridge
//
//  Created by Ethan Lipnik.
//

import Foundation

#if os(macOS)
enum CodexNativeApplyPatch {
static func run(_ input: [String: Any]) -> [String: Any] {
    let started = Date()
    let maxOutputBytes = max(1, intValue(input["maxOutputBytes"])
        ?? intValue(input["max_output_bytes"])
        ?? 64 * 1024)

    let stdout: String
    let stderr: String
    let exitCode: Int
    do {
        let request = try request(from: input)
        let affected = try apply(request.patch, workspaceRoot: request.workspaceRoot, cwd: request.cwd)
        stdout = summary(affected)
        stderr = ""
        exitCode = 0
    } catch let error as NativeApplyPatchError {
        stdout = ""
        stderr = "\(error.message)\n"
        exitCode = error.exitCode
    } catch {
        stdout = ""
        stderr = "\(error.localizedDescription)\n"
        exitCode = 1
    }

    return response(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        started: started,
        maxOutputBytes: maxOutputBytes
    )
}

static func request(from input: [String: Any]) throws -> NativeApplyPatchRequest {
    let patch = input["patch"] as? String ?? ""
    guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NativeApplyPatchError("patch is empty", exitCode: 2)
    }

    let rootPath = input["workspaceRoot"] as? String
        ?? input["workspace_root"] as? String
        ?? FileManager.default.currentDirectoryPath
    let workspaceRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
    let cwd = try workingDirectory(root: workspaceRoot, rawWorkdir: input["workdir"] as? String ?? input["cwd"] as? String ?? "")
    return NativeApplyPatchRequest(workspaceRoot: workspaceRoot, cwd: cwd, patch: patch)
}

static func workingDirectory(root: URL, rawWorkdir: String) throws -> URL {
    let candidate = rawWorkdir.isEmpty
        ? root
        : rawWorkdir.hasPrefix("/")
            ? URL(fileURLWithPath: rawWorkdir)
            : root.appending(path: rawWorkdir, directoryHint: .isDirectory)
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard isInsideWorkspace(resolved, root: root) else {
        throw NativeApplyPatchError("\(resolved.path): escapes workspace", exitCode: 2)
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NativeApplyPatchError("\(resolved.path): no such directory", exitCode: 2)
    }
    return resolved
}

static func summary(_ affected: AffectedPaths) -> String {
    var lines = ["Success. Updated the following files:"]
    lines.append(contentsOf: affected.added.map { "A \($0)" })
    lines.append(contentsOf: affected.modified.map { "M \($0)" })
    lines.append(contentsOf: affected.deleted.map { "D \($0)" })
    return lines.joined(separator: "\n") + "\n"
}

static func response(
    exitCode: Int,
    stdout: String,
    stderr: String,
    started: Date,
    maxOutputBytes: Int
) -> [String: Any] {
    let rawOutput: String
    if stderr.isEmpty {
        rawOutput = stdout
    } else if stdout.isEmpty {
        rawOutput = stderr
    } else {
        rawOutput = stdout + stderr
    }
    let truncated = truncateUTF8(rawOutput, maxBytes: maxOutputBytes)
    return [
        "exit_code": exitCode,
        "stdout": stdout,
        "stderr": stderr,
        "output": truncated.text,
        "wall_time_seconds": Date().timeIntervalSince(started),
        "truncated": truncated.wasTruncated,
    ]
}

static func truncateUTF8(_ text: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
    let data = Data(text.utf8)
    guard data.count > maxBytes else {
        return (text, false)
    }

    var byteCount = maxBytes
    while byteCount > 0 {
        let prefix = Data(data.prefix(byteCount))
        if let truncated = String(data: prefix, encoding: .utf8) {
            return ("\(truncated)\n[output truncated]\n", true)
        }
        byteCount -= 1
    }
    return ("\n[output truncated]\n", true)
}

static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as Double:
        return Int(value)
    case let value as String:
        return Int(value)
    default:
        return nil
    }
}
}
#endif
