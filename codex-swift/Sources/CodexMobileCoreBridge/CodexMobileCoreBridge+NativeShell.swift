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
    #if os(macOS)
    static func runNativeShell(
        _ input: [String: Any],
        outputHandler: (@Sendable (String) -> Void)?
    ) -> [String: Any] {
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
        let useLoginShell = input["login"] as? Bool ?? true

        let workdir: URL
        do {
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

        let stdout = ShellOutputCollector(maxBytes: maxOutputBytes)
        let stderr = ShellOutputCollector(maxBytes: maxOutputBytes)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stdout.append(data)
            if !data.isEmpty {
                outputHandler?(String(decoding: data, as: UTF8.self))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stderr.append(data)
            if !data.isEmpty {
                outputHandler?(String(decoding: data, as: UTF8.self))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = useLoginShell ? ["-lc", command] : ["-c", command]
        process.currentDirectoryURL = workdir
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return shellResponse(
                exitCode: 126,
                stdout: "",
                stderr: "\(error.localizedDescription)\n",
                started: started,
                truncated: false
            )
        }

        var timedOut = false
        if termination.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            timedOut = true
            process.terminate()
            if termination.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + .seconds(1))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stdout.append(remainingStdout)
        if !remainingStdout.isEmpty {
            outputHandler?(String(decoding: remainingStdout, as: UTF8.self))
        }
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stderr.append(remainingStderr)
        if !remainingStderr.isEmpty {
            outputHandler?(String(decoding: remainingStderr, as: UTF8.self))
        }

        if timedOut {
            let timeoutData = Data("Command timed out after \(timeoutMilliseconds) ms.\n".utf8)
            stderr.append(timeoutData)
            outputHandler?(String(decoding: timeoutData, as: UTF8.self))
        }

        return shellResponse(
            exitCode: timedOut ? 124 : Int(process.terminationStatus),
            stdout: stdout.string(),
            stderr: stderr.string(),
            started: started,
            truncated: stdout.wasTruncated || stderr.wasTruncated
        )
    }
    #endif

}
