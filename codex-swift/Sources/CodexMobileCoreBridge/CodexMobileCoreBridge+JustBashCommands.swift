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
    static func seedJailedCommandStubs(from bash: Bash, into fileSystem: CodexJailedBashFileSystem) async {
        let names = await bash.commandNames
        for name in names where !name.contains("/") {
            fileSystem.seedCommandStub(named: name)
        }
        for name in justBashShellBuiltinNames {
            fileSystem.seedCommandStub(named: name)
        }
    }

    static func justBashHostCompatibilityCommands() -> [AnyBashCommand] {
        var commands = [
            justBashShellLauncherCommand(named: "sh"),
            justBashShellLauncherCommand(named: "bash"),
            justBashShellLauncherCommand(named: "/bin/sh"),
            justBashShellLauncherCommand(named: "/bin/bash"),
            justBashShellLauncherCommand(named: "/usr/bin/bash"),
            justBashEnvCommand(named: "/usr/bin/env"),
            justBashEnvCommand(named: "/bin/env"),
            justBashNodeCommand(named: "node"),
            justBashNodeCommand(named: "/bin/node"),
            justBashNodeCommand(named: "/usr/bin/node"),
        ]
        var seen = Set(commands.map(\.name))
        for name in justBashPathAliasCommandNames {
            for prefix in ["/bin/", "/usr/bin/"] {
                let alias = "\(prefix)\(name)"
                guard seen.insert(alias).inserted else {
                    continue
                }
                commands.append(justBashPathAliasCommand(named: alias, targetName: name))
            }
        }
        return commands
    }

    static func justBashEmbeddedRuntimes() -> [any EmbeddedRuntime] {
        #if canImport(JustBashJavaScript)
        return [JavaScriptRuntime()]
        #else
        return []
        #endif
    }

    static func justBashPathAliasCommand(named alias: String, targetName: String) -> AnyBashCommand {
        AnyBashCommand(name: alias) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(alias): shell execution unavailable", exitCode: 126)
            }
            let script = ([targetName] + args).map(shellQuoteForJustBash).joined(separator: " ")
            return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
        }
    }

    static func justBashShellLauncherCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            switch shellLauncherScript(from: args, context: context, commandName: name) {
            case .script(let script):
                guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ExecResult.success()
                }
                return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
            case .result(let result):
                return result
            }
        }
    }

    static func justBashEnvCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            let parsed = envCommandScriptArguments(args)
            guard parsed.isSupported else {
                return ExecResult.failure("\(name): unsupported option", exitCode: 125)
            }
            let environment = parsed.ignoreExistingEnvironment
                ? parsed.environment
                : context.environment.merging(parsed.environment, uniquingKeysWith: { _, new in new })
            guard !parsed.commandArguments.isEmpty else {
                let output = environment.keys
                    .sorted()
                    .map { "\($0)=\(environment[$0] ?? "")" }
                    .joined(separator: "\n")
                return ExecResult.success(output + (output.isEmpty ? "" : "\n"))
            }

            let commandScript = parsed.commandArguments.map(shellQuoteForJustBash).joined(separator: " ")
            return await executeSubshell(scriptWithInheritedEnvironment(commandScript, environment: environment))
        }
    }

    static func justBashNodeCommand(named name: String) -> AnyBashCommand {
        AnyBashCommand(name: name) { args, context in
            guard let executeSubshell = context.executeSubshell else {
                return ExecResult.failure("\(name): shell execution unavailable", exitCode: 126)
            }

            switch nodeJSExecArguments(from: args, stdin: context.stdin, commandName: name) {
            case .arguments(let jsExecArguments):
                let script = (["js-exec"] + jsExecArguments).map(shellQuoteForJustBash).joined(separator: " ")
                return await executeSubshell(scriptWithInheritedEnvironment(script, environment: context.environment))
            case .result(let result):
                return result
            }
        }
    }

    static func nodeJSExecArguments(
        from args: [String],
        stdin: String,
        commandName: String
    ) -> NodeLauncherResolution {
        guard !args.isEmpty else {
            return stdin.isEmpty ? .arguments(["-c", ""]) : .arguments(["-c", stdin])
        }

        var isModule = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }

            switch argument {
            case "-v", "--version":
                return .result(ExecResult.success("v20.0.0-justbash\n"))
            case "-h", "--help":
                return .result(ExecResult.success("""
                Usage: node [options] [script.js] [arguments]

                iOS Codex routes node-compatible JavaScript through JustBashJavaScript.
                Supported: -e/--eval, -p/--print, --input-type=module, script files.

                """))
            case "-e", "--eval":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): \(argument) requires an argument", exitCode: 2))
                }
                var jsExecArguments = isModule ? ["-m"] : []
                jsExecArguments += ["-c", args[index + 1]]
                jsExecArguments += Array(args.dropFirst(index + 2))
                return .arguments(jsExecArguments)
            case "-p", "--print":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): \(argument) requires an argument", exitCode: 2))
                }
                var jsExecArguments = isModule ? ["-m"] : []
                jsExecArguments += ["-c", "console.log(\(args[index + 1]));"]
                jsExecArguments += Array(args.dropFirst(index + 2))
                return .arguments(jsExecArguments)
            case "--input-type=module", "--experimental-modules":
                isModule = true
                index += 1
                continue
            case "--input-type=commonjs", "--no-warnings", "--enable-source-maps", "--trace-warnings":
                index += 1
                continue
            case "--input-type":
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): --input-type requires an argument", exitCode: 2))
                }
                let value = args[index + 1]
                if value == "module" {
                    isModule = true
                } else if value != "commonjs" {
                    return .result(ExecResult.failure("\(commandName): unsupported --input-type=\(value)", exitCode: 2))
                }
                index += 2
                continue
            case "-":
                return stdin.isEmpty ? .arguments(isModule ? ["-m", "-c", ""] : ["-c", ""]) : .arguments(isModule ? ["-m", "-c", stdin] : ["-c", stdin])
            default:
                if argument.hasPrefix("-") {
                    return .result(ExecResult.failure("\(commandName): unsupported option \(argument)", exitCode: 125))
                }
            }
            break
        }

        guard index < args.count else {
            return stdin.isEmpty ? .arguments(isModule ? ["-m", "-c", ""] : ["-c", ""]) : .arguments(isModule ? ["-m", "-c", stdin] : ["-c", stdin])
        }

        var jsExecArguments = isModule ? ["-m"] : []
        jsExecArguments.append(args[index])
        jsExecArguments += Array(args.dropFirst(index + 1))
        return .arguments(jsExecArguments)
    }

    enum NodeLauncherResolution {
        case arguments([String])
        case result(ExecResult)
    }

    static func shellLauncherScript(
        from args: [String],
        context: CommandContext,
        commandName: String
    ) -> ShellLauncherResolution {
        guard !args.isEmpty else {
            return .script("")
        }

        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }
            if argument == "-c" || (argument.hasPrefix("-") && argument.dropFirst().contains("c")) {
                guard index + 1 < args.count else {
                    return .result(ExecResult.failure("\(commandName): option requires an argument -- c", exitCode: 2))
                }
                return .script(args[index + 1])
            }
            guard argument.hasPrefix("-") else {
                break
            }
            index += 1
        }

        guard index < args.count else {
            return .script("")
        }

        let scriptPath = args[index]
        do {
            let data = try context.fileSystem.readFile(path: scriptPath, relativeTo: context.cwd)
            return .script(String(decoding: data, as: UTF8.self))
        } catch {
            return .result(ExecResult.failure("\(commandName): \(scriptPath): \(error.localizedDescription)", exitCode: 127))
        }
    }

    enum ShellLauncherResolution {
        case script(String)
        case result(ExecResult)
    }

    static func envCommandScriptArguments(_ args: [String]) -> (
        environment: [String: String],
        commandArguments: [String],
        ignoreExistingEnvironment: Bool,
        isSupported: Bool
    ) {
        var environment: [String: String] = [:]
        var ignoreExistingEnvironment = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "-i", "--ignore-environment":
                ignoreExistingEnvironment = true
                index += 1
                continue
            case "-S":
                guard index + 1 < args.count else {
                    return (environment, [], ignoreExistingEnvironment, false)
                }
                let split = args[index + 1].split(separator: " ").map(String.init)
                return (environment, split + Array(args.dropFirst(index + 2)), ignoreExistingEnvironment, true)
            default:
                if argument.hasPrefix("-") {
                    return (environment, [], ignoreExistingEnvironment, false)
                }
                if let assignmentRange = argument.range(of: "="),
                   assignmentRange.lowerBound != argument.startIndex
                {
                    let key = String(argument[..<assignmentRange.lowerBound])
                    let value = String(argument[assignmentRange.upperBound...])
                    environment[key] = value
                    index += 1
                    continue
                }
                return (environment, Array(args.dropFirst(index)), ignoreExistingEnvironment, true)
            }
        }
        return (environment, [], ignoreExistingEnvironment, true)
    }

    static func scriptWithInheritedEnvironment(_ script: String, environment: [String: String]) -> String {
        let exports = environment
            .filter { key, _ in isShellIdentifier(key) }
            .map { key, value in
                "export \(key)=\(shellQuoteForJustBash(value))"
            }
            .sorted()
            .joined(separator: "\n")
        return exports.isEmpty ? script : "\(exports)\n\(script)"
    }

    static func isShellIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_").contains(first)
        else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains(scalar)
        }
    }

    static func shellQuoteForJustBash(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        if value.unicodeScalars.allSatisfy({ scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
                .contains(scalar)
        }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let justBashShellBuiltinNames = [
        ":", ".", "[", "alias", "break", "builtin", "cd", "command", "compgen",
        "complete", "compopt", "continue", "declare", "dirs", "echo", "eval",
        "exec", "exit", "export", "false", "getopts", "hash", "let", "local",
        "mapfile", "popd", "printf", "pushd", "pwd", "read", "readarray",
        "readonly", "return", "set", "shift", "shopt", "source", "test",
        "trap", "true", "type", "typeset", "unalias", "unset", "which",
    ]

    static let justBashPathAliasCommandNames = [
        "awk", "base64", "basename", "bash", "bc", "bunzip2", "bzcat", "bzip2",
        "cat", "chmod", "chronic", "cksum", "clear", "column", "combine",
        "comm", "cp", "curl", "cut", "date", "df", "diff", "dirname", "du",
        "egrep", "env", "errno", "expr", "expand", "fgrep", "file", "find",
        "fmt", "fold", "free", "getconf", "git", "grep", "gunzip", "gzip",
        "head", "help", "hexdump", "history", "hostname", "htmlToMarkdown",
        "iconv", "ifdata", "join", "jot", "jq", "kill", "killall", "ln",
        "look", "ls", "md5sum", "mkdir", "mktemp", "mv", "nl", "nproc", "od",
        "paste", "pathchk", "pee", "pr", "ps", "readlink", "realpath", "rev",
        "rg", "rm", "rmdir", "sed", "seq", "sh", "sha1sum", "sha256sum", "shuf",
        "sleep", "sort", "sponge", "split", "sqlite3", "stat", "strings", "sum",
        "tac", "tail", "tar", "tee", "time", "timeout", "touch", "tput", "tr",
        "tree", "ts", "tsort", "tty", "uname", "unexpand", "uniq", "unzip",
        "uptime", "uuencode", "vidir", "vipe", "wc", "whereis", "which",
        "whoami", "xan", "xargs", "xxd", "yes", "yq", "zcat", "zip",
    ]
}
#endif
