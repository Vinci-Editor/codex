//
//  Created by Ethan Lipnik
//

import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(CodexMobileCore)
import CodexMobileCore
#endif
#if canImport(JustBash) && canImport(JustBashFS)
import JustBash
import JustBashCommands
import JustBashFS
#endif
#if canImport(JustBashJavaScript)
import JustBashJavaScript
#endif

extension CodexMobileCoreBridge {
    static func fallbackEmulateShell(_ input: [String: Any]) -> [String: Any] {
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        return [
            "exit_code": 127,
            "stdout": "",
            "stderr": "\(command): shell emulator unavailable\n",
            "output": "\(command): shell emulator unavailable\n",
            "wall_time_seconds": 0,
            "truncated": false,
        ]
    }

    static func shellOutputLimit(_ input: [String: Any]) -> Int {
        max(1, intValue(input["maxOutputBytes"])
            ?? intValue(input["max_output_bytes"])
            ?? intValue(input["max_output_tokens"]).map { $0 * 4 }
            ?? 64 * 1024)
    }

    static func shellWorkspaceRoot(_ input: [String: Any]) throws -> URL {
        let rootPath = input["workspaceRoot"] as? String
            ?? input["workspace_root"] as? String
            ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: root.path,
                NSLocalizedDescriptionKey: "\(root.path): no such directory",
            ])
        }
        return root
    }

    static func shellWorkingDirectory(_ input: [String: Any]) throws -> URL {
        let root = try shellWorkspaceRoot(input)
        let rawWorkdir = input["workdir"] as? String ?? input["cwd"] as? String ?? ""
        let candidate = rawWorkdir.isEmpty
            ? root
            : rawWorkdir.hasPrefix("/")
                ? URL(fileURLWithPath: rawWorkdir)
                : root.appending(path: rawWorkdir, directoryHint: .isDirectory)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: resolved.path,
                NSLocalizedDescriptionKey: "\(resolved.path): escapes workspace",
            ])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: resolved.path,
                NSLocalizedDescriptionKey: "\(resolved.path): no such directory",
            ])
        }
        return resolved
    }

    static func virtualShellWorkingDirectory(root: URL, workdir: URL) -> String {
        let rootPath = root.path
        let workdirPath = workdir.path
        guard workdirPath != rootPath else {
            return "/"
        }
        let relativePath = workdirPath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relativePath.isEmpty ? "/" : "/\(relativePath)"
    }

    static func shellResponse(
        exitCode: Int,
        stdout: String,
        stderr: String,
        started: Date,
        truncated: Bool
    ) -> [String: Any] {
        let output: String
        if stderr.isEmpty {
            output = stdout
        } else if stdout.isEmpty {
            output = stderr
        } else {
            output = stdout + stderr
        }
        return [
            "exit_code": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "output": output,
            "wall_time_seconds": Date().timeIntervalSince(started),
            "truncated": truncated,
        ]
    }

    static func limitedShellText(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let collector = ShellOutputCollector(maxBytes: maxBytes)
        collector.append(Data(text.utf8))
        return (collector.string(), collector.wasTruncated)
    }

    final class ShellOutputCollector: @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        var wasTruncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return truncated
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else {
                return
            }
            lock.lock()
            defer { lock.unlock() }

            let remaining = maxBytes - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            let wasTruncated = truncated
            lock.unlock()

            var text = String(decoding: snapshot, as: UTF8.self)
            if wasTruncated {
                text += "\n[output truncated]\n"
            }
            return text
        }
    }

}
