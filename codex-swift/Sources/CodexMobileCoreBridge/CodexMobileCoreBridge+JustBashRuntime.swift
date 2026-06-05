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

#if canImport(JustBash) && canImport(JustBashFS)
extension CodexMobileCoreBridge {
    static func runJustBashShell(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)?
    ) async -> [String: Any] {
        let started = Date()
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return shellResponse(
                exitCode: 64,
                stdout: "",
                stderr: "Missing command.\n",
                started: started,
                truncated: false
            )
        }

        let maxOutputBytes = shellOutputLimit(input)
        let timeoutMilliseconds = max(1, intValue(input["timeout_ms"]) ?? 120_000)

        let root: URL
        let workdir: URL
        do {
            root = try shellWorkspaceRoot(input)
            workdir = try shellWorkingDirectory(input)
        } catch {
            return shellResponse(
                exitCode: 1,
                stdout: "",
                stderr: "\(error.localizedDescription)\n",
                started: started,
                truncated: false
            )
        }

        let cwd = virtualShellWorkingDirectory(root: root, workdir: workdir)
        let fileSystem = CodexJailedBashFileSystem(rootURL: root)
        let executionLimits = ExecutionLimits(
            maxInputLength: max(256_000, command.utf8.count + 1024),
            maxTokenCount: 16_000,
            maxCommandCount: 10_000,
            maxOutputLength: max(1_048_576, maxOutputBytes * 2),
            maxPipelineLength: 64,
            maxCallDepth: 100,
            maxLoopIterations: 10_000,
            maxSubstitutionDepth: 50
        )
        var options = BashOptions(
            env: [
                "HOME": "/",
                "USER": "coder",
                "LOGNAME": "coder",
                "PWD": cwd,
                "OLDPWD": cwd,
                "TMPDIR": cwd,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/bash",
                "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8",
            ],
            cwd: cwd,
            executionLimits: executionLimits,
            customCommands: justBashHostCompatibilityCommands(),
            filesystem: fileSystem,
            allowedURLPrefixes: [],
            embeddedRuntimes: justBashEmbeddedRuntimes()
        )
        options.enableOAIPrimaryRuntime()
        let bash = Bash(options: options)
        await seedJailedCommandStubs(from: bash, into: fileSystem)

        let outcome = await runJustBash(command: command, bash: bash, timeoutMilliseconds: timeoutMilliseconds)
        let exitCode: Int
        let rawStdout: String
        let rawStderr: String
        switch outcome {
        case .completed(let result):
            exitCode = result.exitCode
            rawStdout = result.stdout
            rawStderr = result.stderr
        case .timedOut:
            exitCode = 124
            rawStdout = ""
            rawStderr = "Command timed out after \(timeoutMilliseconds) ms.\n"
        }

        let stdout = limitedShellText(rawStdout, maxBytes: maxOutputBytes)
        let stderr = limitedShellText(rawStderr, maxBytes: maxOutputBytes)
        let response = shellResponse(
            exitCode: exitCode,
            stdout: stdout.text,
            stderr: stderr.text,
            started: started,
            truncated: stdout.truncated || stderr.truncated
        )
        if let output = response["output"] as? String, !output.isEmpty {
            outputHandler?(output)
        }
        return response
    }

    enum JustBashExecutionOutcome: Sendable {
        case completed(ExecResult)
        case timedOut
    }

    final class JustBashExecutionRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<JustBashExecutionOutcome, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<JustBashExecutionOutcome, Never>) {
            self.continuation = continuation
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            let shouldCancel: Bool
            lock.lock()
            if continuation == nil {
                shouldCancel = true
            } else {
                timeoutTask = task
                shouldCancel = false
            }
            lock.unlock()

            if shouldCancel {
                task.cancel()
            }
        }

        func finish(_ outcome: JustBashExecutionOutcome) {
            let continuationToResume: CheckedContinuation<JustBashExecutionOutcome, Never>?
            let timeoutTaskToCancel: Task<Void, Never>?
            lock.lock()
            continuationToResume = continuation
            continuation = nil
            timeoutTaskToCancel = timeoutTask
            timeoutTask = nil
            lock.unlock()

            timeoutTaskToCancel?.cancel()
            continuationToResume?.resume(returning: outcome)
        }
    }

    static func runJustBash(
        command: String,
        bash: Bash,
        timeoutMilliseconds: Int
    ) async -> JustBashExecutionOutcome {
        await withCheckedContinuation { continuation in
            let race = JustBashExecutionRace(continuation)
            let execTask = Task {
                let result = await bash.exec(command)
                race.finish(.completed(result))
            }
            let timeoutTask = Task {
                let timeout = UInt64(min(timeoutMilliseconds, 3_600_000)) * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: timeout)
                } catch {
                    return
                }
                execTask.cancel()
                race.finish(.timedOut)
            }
            race.setTimeoutTask(timeoutTask)
        }
    }

    static func emulatePortableShellForTesting(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) async -> [String: Any] {
        await runJustBashShell(input, outputHandler: outputHandler)
    }
}
#endif
