//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func executeListDir(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let dirPath = arguments["dir_path"] as? String ?? "."
        let offset = Self.intValue(arguments["offset"]) ?? 0
        let limit = Self.intValue(arguments["limit"]) ?? 200
        let depth = Self.intValue(arguments["depth"]) ?? 1
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: dirPath)
            let entries = try Self.listDirectory(root: root, target: target, depth: max(depth, 1))
            let page = entries.dropFirst(max(offset, 0)).prefix(max(limit, 1))
            let output = page.isEmpty ? "No entries." : page.joined(separator: "\n")
            return CodexToolResult(output: output)
        }
    }

    func executeReadFile(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let offset = max(Self.intValue(arguments["offset"]) ?? 0, 0)
        let limit = max(Self.intValue(arguments["limit"]) ?? 400, 1)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return CodexToolResult(output: "\(path): is a directory", success: false)
            }

            let text = try String(contentsOf: target, encoding: .utf8)
            guard arguments["offset"] != nil || arguments["limit"] != nil else {
                if text.count <= 64_000 {
                    return CodexToolResult(output: text)
                }
                let index = text.index(text.startIndex, offsetBy: 64_000)
                return CodexToolResult(output: "\(text[..<index])\n[truncated]")
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else {
                return CodexToolResult(output: "")
            }

            let page = lines.dropFirst(offset).prefix(limit)
            let output = page.joined(separator: "\n")
            if offset + page.count < lines.count {
                return CodexToolResult(output: "\(output)\n[showing lines \(offset + 1)-\(offset + page.count) of \(lines.count)]")
            }
            return CodexToolResult(output: output)
        }
    }

    func executeSearchFiles(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let query = arguments["query"] as? String ?? arguments["pattern"] as? String ?? ""
        let path = arguments["path"] as? String ?? "."
        let caseSensitive = arguments["case_sensitive"] as? Bool ?? false
        let limit = max(Self.intValue(arguments["limit"]) ?? 100, 1)
        guard !query.isEmpty else {
            return CodexToolResult(output: "Missing query.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            let matches = try Self.searchFiles(
                root: root,
                target: target,
                query: query,
                caseSensitive: caseSensitive,
                limit: limit
            )
            return CodexToolResult(output: matches.isEmpty ? "No matches." : matches.joined(separator: "\n"))
        }
    }

    func executeShell(
        _ call: CodexToolCall,
        progress: CodexToolProgressHandler? = nil
    ) async throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let command = arguments["command"] as? String ?? arguments["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing command.", success: false)
        }
        if let unsupportedFeature = Self.unsupportedShellExecutionFeature(for: call.name, arguments: arguments) {
            return CodexToolResult(output: unsupportedFeature, success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try await workspace.withSecurityScope { root in
            var input: [String: Any] = [
                "workspaceRoot": root.path,
                "command": command,
                "maxOutputBytes": Self.intValue(arguments["maxOutputBytes"])
                    ?? Self.intValue(arguments["max_output_bytes"])
                    ?? Self.intValue(arguments["max_output_tokens"]).map { $0 * 4 }
                    ?? 64 * 1024,
            ]
            if let workdir = arguments["workdir"] as? String {
                input["workdir"] = workdir
            }
            if let timeoutMilliseconds = Self.intValue(arguments["timeout_ms"]) {
                input["timeout_ms"] = timeoutMilliseconds
            }
            if arguments["login"] != nil {
                input["login"] = Self.boolValue(arguments["login"])
            }
            let response = try await CodexMobileCoreBridge.emulateShell(input) { delta in
                progress?(.outputDelta(delta))
            }
            let exitCode = Self.intValue(response["exit_code"]) ?? 1
            let output = response["output"] as? String ?? ""
            return CodexToolResult(
                output: output.isEmpty ? "(no output)" : output,
                success: exitCode == 0
            )
        }
    }

    static func unsupportedShellExecutionFeature(for toolName: String, arguments: [String: Any]) -> String? {
        guard toolName == "exec_command" else {
            return nil
        }
        if let sessionID = trimmedNonEmpty(arguments["session_id"] as? String) {
            return "CodexKit exec_command is one-shot and does not support ongoing shell sessions (`session_id`: \(sessionID)). Rerun without session_id; interactive stdin/PTY support requires Codex app-server process execution."
        }
        if boolValue(arguments["tty"]) {
            return "CodexKit exec_command does not support TTY or interactive shell execution. Rerun with tty=false or omit tty."
        }
        return nil
    }

    func executeApplyPatch(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let patch = arguments["patch"] as? String ?? ""
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing patch.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }
        guard !workspace.readOnly else {
            return CodexToolResult(output: "Workspace is read-only.", success: false)
        }

        return try workspace.withSecurityScope { root in
            var input: [String: Any] = [
                "workspaceRoot": root.path,
                "patch": patch,
                "maxOutputBytes": 64 * 1024,
            ]
            if let workdir = arguments["workdir"] as? String {
                input["workdir"] = workdir
            }
            let response = try CodexMobileCoreBridge.applyPatch(input)
            let exitCode = Self.intValue(response["exit_code"]) ?? 1
            let output = response["output"] as? String ?? ""
            return CodexToolResult(
                output: output.isEmpty ? "(no output)" : output,
                success: exitCode == 0
            )
        }
    }

    func executeWriteFile(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let content = arguments["content"] as? String ?? ""
        let createDirectories = arguments["create_directories"] as? Bool ?? true
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }
        guard !workspace.readOnly else {
            return CodexToolResult(output: "Workspace is read-only.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveWorkspaceURL(root: root, rawPath: path, mustExist: false)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return CodexToolResult(output: "\(path): is a directory", success: false)
            }

            let parent = target.deletingLastPathComponent()
            if createDirectories {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: parent.path) {
                return CodexToolResult(output: "\(parent.path): no such directory", success: false)
            }

            try content.write(to: target, atomically: true, encoding: .utf8)
            let relativePath = Self.relativeWorkspacePath(root: root, url: target)
            return CodexToolResult(output: "Wrote \(relativePath) (\(content.utf8.count) bytes).")
        }
    }

    func executeViewImage(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let path = arguments["path"] as? String ?? arguments["file_path"] as? String ?? ""
        let detail = arguments["detail"] as? String
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexToolResult(output: "Missing path.", success: false)
        }
        guard detail == nil || detail == "high" || detail == "original" else {
            return CodexToolResult(
                output: "view_image.detail only supports `high` or `original`; omit `detail` for default high resized behavior, got `\(detail ?? "")`",
                success: false
            )
        }
        guard let workspace = configuration.workspace else {
            return CodexToolResult(output: "No workspace selected.", success: false)
        }

        return try workspace.withSecurityScope { root in
            let target = try Self.resolveExistingWorkspaceURL(root: root, rawPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return CodexToolResult(output: "\(path): is not an image file", success: false)
            }

            do {
                let image = try Self.imageDataURL(for: target, detail: detail)
                let relativePath = Self.relativeWorkspacePath(root: root, url: target)
                return CodexToolResult(
                    output: "Viewed \(relativePath)",
                    responseOutput: .inputImage(imageURL: image.dataURL, detail: image.detail)
                )
            } catch {
                return CodexToolResult(
                    output: "unable to process image at `\(path)`: \(error.localizedDescription)",
                    success: false
                )
            }
        }
    }

    func executeUpdatePlan(_ call: CodexToolCall) throws -> CodexToolResult {
        let arguments = try Self.decodeArguments(call.arguments)
        let explanation = (arguments["explanation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPlan = arguments["plan"] as? [[String: Any]] else {
            return CodexToolResult(output: "Missing plan.", success: false)
        }

        var items: [CodexPlanItem] = []
        var inProgressCount = 0
        for rawItem in rawPlan {
            let step = (rawItem["step"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !step.isEmpty else {
                return CodexToolResult(output: "update_plan step cannot be empty.", success: false)
            }
            let statusValue = rawItem["status"] as? String ?? ""
            guard let status = CodexPlanItem.Status(rawValue: statusValue) else {
                return CodexToolResult(output: "Unsupported update_plan status: \(statusValue)", success: false)
            }
            if status == .inProgress {
                inProgressCount += 1
            }
            items.append(CodexPlanItem(step: step, status: status))
        }

        guard inProgressCount <= 1 else {
            return CodexToolResult(output: "At most one plan step can be in_progress.", success: false)
        }

        return CodexToolResult(
            output: "Plan updated",
            planUpdate: CodexPlanUpdate(
                explanation: explanation?.isEmpty == true ? nil : explanation,
                items: items
            )
        )
    }
}
