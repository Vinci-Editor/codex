import Foundation

#if os(macOS)
extension CodexMobileCoreBridge {
    static func nativeApplyPatch(_ input: [String: Any]) -> [String: Any] {
        NativeApplyPatch.run(input)
    }
}

private enum NativeApplyPatch {
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

    private static func request(from input: [String: Any]) throws -> NativeApplyPatchRequest {
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

    private static func workingDirectory(root: URL, rawWorkdir: String) throws -> URL {
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

    private static func apply(_ patch: String, workspaceRoot: URL, cwd: URL) throws -> AffectedPaths {
        let hunks: [PatchHunk]
        do {
            hunks = try PatchParser.parse(patch)
        } catch let error as PatchParser.ParseError {
            throw NativeApplyPatchError(error.userMessage, exitCode: 1)
        }

        guard !hunks.isEmpty else {
            throw NativeApplyPatchError("No files were modified.", exitCode: 1)
        }

        var affected = AffectedPaths()
        for hunk in hunks {
            switch hunk {
            case .addFile(let path, let contents):
                let target = try writableURL(rawPath: path, cwd: cwd, workspaceRoot: workspaceRoot)
                try ensureNotDirectory(target, displayPath: path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: target, atomically: true, encoding: .utf8)
                affected.added.append(path)

            case .deleteFile(let path):
                let target = try existingFileURL(rawPath: path, cwd: cwd, workspaceRoot: workspaceRoot)
                try FileManager.default.removeItem(at: target)
                affected.deleted.append(path)

            case .updateFile(let path, let movePath, let chunks):
                let source = try existingFileURL(rawPath: path, cwd: cwd, workspaceRoot: workspaceRoot)
                let original = try String(contentsOf: source, encoding: .utf8)
                let newContents = try deriveNewContents(original: original, path: path, chunks: chunks)

                if let movePath {
                    let destination = try writableURL(rawPath: movePath, cwd: cwd, workspaceRoot: workspaceRoot)
                    try ensureNotDirectory(destination, displayPath: movePath)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try newContents.write(to: destination, atomically: true, encoding: .utf8)
                    try FileManager.default.removeItem(at: source)
                    affected.modified.append(movePath)
                } else {
                    try newContents.write(to: source, atomically: true, encoding: .utf8)
                    affected.modified.append(path)
                }
            }
        }
        return affected
    }

    private static func existingFileURL(rawPath: String, cwd: URL, workspaceRoot: URL) throws -> URL {
        let resolved = resolve(rawPath: rawPath, cwd: cwd).standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(resolved, root: workspaceRoot) else {
            throw NativeApplyPatchError("\(rawPath) escapes workspace", exitCode: 1)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw NativeApplyPatchError("\(rawPath): no such file or directory", exitCode: 1)
        }
        guard !isDirectory.boolValue else {
            throw NativeApplyPatchError("\(rawPath): path is a directory", exitCode: 1)
        }
        return resolved
    }

    private static func writableURL(rawPath: String, cwd: URL, workspaceRoot: URL) throws -> URL {
        let candidate = resolve(rawPath: rawPath, cwd: cwd).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard isInsideWorkspace(resolved, root: workspaceRoot) else {
            throw NativeApplyPatchError("\(rawPath) escapes workspace", exitCode: 1)
        }

        let parent = resolved.deletingLastPathComponent()
        let existingParent = try nearestExistingAncestor(parent)
        let canonicalParent = existingParent.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(canonicalParent, root: workspaceRoot) else {
            throw NativeApplyPatchError("\(rawPath) escapes workspace", exitCode: 1)
        }
        return resolved
    }

    private static func resolve(rawPath: String, cwd: URL) -> URL {
        rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : cwd.appending(path: rawPath, directoryHint: .inferFromPath)
    }

    private static func nearestExistingAncestor(_ url: URL) throws -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw NativeApplyPatchError("\(url.path): missing parent directory", exitCode: 1)
            }
            current = parent
        }
        return current
    }

    private static func ensureNotDirectory(_ url: URL, displayPath: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw NativeApplyPatchError("\(displayPath): path is a directory", exitCode: 1)
        }
    }

    private static func isInsideWorkspace(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func deriveNewContents(original: String, path: String, chunks: [UpdateFileChunk]) throws -> String {
        var originalLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if originalLines.last == "" {
            originalLines.removeLast()
        }

        let replacements = try computeReplacements(originalLines: originalLines, path: path, chunks: chunks)
        var newLines = originalLines
        for replacement in replacements.reversed() {
            var remainingRemovals = replacement.oldLength
            while remainingRemovals > 0 && replacement.startIndex < newLines.count {
                newLines.remove(at: replacement.startIndex)
                remainingRemovals -= 1
            }
            newLines.insert(contentsOf: replacement.newLines, at: min(replacement.startIndex, newLines.count))
        }

        if newLines.last != "" {
            newLines.append("")
        }
        return newLines.joined(separator: "\n")
    }

    private static func computeReplacements(
        originalLines: [String],
        path: String,
        chunks: [UpdateFileChunk]
    ) throws -> [Replacement] {
        var replacements: [Replacement] = []
        var lineIndex = 0

        for chunk in chunks {
            if let changeContext = chunk.changeContext {
                guard let index = seekSequence(originalLines, pattern: [changeContext], start: lineIndex, eof: false) else {
                    throw NativeApplyPatchError("Failed to find context '\(changeContext)' in \(path)", exitCode: 1)
                }
                lineIndex = index + 1
            }

            if chunk.oldLines.isEmpty {
                let insertionIndex = originalLines.last == "" ? originalLines.count - 1 : originalLines.count
                replacements.append(Replacement(startIndex: insertionIndex, oldLength: 0, newLines: chunk.newLines))
                continue
            }

            var pattern = chunk.oldLines
            var newLines = chunk.newLines
            var found = seekSequence(originalLines, pattern: pattern, start: lineIndex, eof: chunk.isEndOfFile)

            if found == nil, pattern.last == "" {
                pattern.removeLast()
                if newLines.last == "" {
                    newLines.removeLast()
                }
                found = seekSequence(originalLines, pattern: pattern, start: lineIndex, eof: chunk.isEndOfFile)
            }

            guard let startIndex = found else {
                throw NativeApplyPatchError(
                    "Failed to find expected lines in \(path):\n\(chunk.oldLines.joined(separator: "\n"))",
                    exitCode: 1
                )
            }

            replacements.append(Replacement(startIndex: startIndex, oldLength: pattern.count, newLines: newLines))
            lineIndex = startIndex + pattern.count
        }

        return replacements.sorted { $0.startIndex < $1.startIndex }
    }

    private static func seekSequence(_ lines: [String], pattern: [String], start: Int, eof: Bool) -> Int? {
        guard !pattern.isEmpty else {
            return start
        }
        guard pattern.count <= lines.count else {
            return nil
        }

        let lastStart = lines.count - pattern.count
        let searchStart = eof ? lastStart : start
        guard searchStart <= lastStart else {
            return nil
        }

        if let exact = firstMatch(in: lines, pattern: pattern, range: searchStart...lastStart, normalize: { $0 }) {
            return exact
        }
        if let rstrip = firstMatch(in: lines, pattern: pattern, range: searchStart...lastStart, normalize: trimEnd) {
            return rstrip
        }
        if let trimmed = firstMatch(in: lines, pattern: pattern, range: searchStart...lastStart, normalize: {
            $0.trimmingCharacters(in: .whitespaces)
        }) {
            return trimmed
        }
        return firstMatch(in: lines, pattern: pattern, range: searchStart...lastStart, normalize: normalizePunctuation)
    }

    private static func firstMatch(
        in lines: [String],
        pattern: [String],
        range: ClosedRange<Int>,
        normalize: (String) -> String
    ) -> Int? {
        for index in range {
            var matches = true
            for offset in pattern.indices {
                if normalize(lines[index + offset]) != normalize(pattern[offset]) {
                    matches = false
                    break
                }
            }
            if matches {
                return index
            }
        }
        return nil
    }

    private static func trimEnd(_ value: String) -> String {
        var result = value
        while let last = result.unicodeScalars.last, CharacterSet.whitespaces.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func normalizePunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).map { character in
            switch character {
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":
                return "-"
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}":
                return "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}":
                return "\""
            case "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}":
                return " "
            default:
                return String(character)
            }
        }.joined()
    }

    private static func summary(_ affected: AffectedPaths) -> String {
        var lines = ["Success. Updated the following files:"]
        lines.append(contentsOf: affected.added.map { "A \($0)" })
        lines.append(contentsOf: affected.modified.map { "M \($0)" })
        lines.append(contentsOf: affected.deleted.map { "D \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func response(
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

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
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

    private static func intValue(_ value: Any?) -> Int? {
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

private struct NativeApplyPatchRequest {
    var workspaceRoot: URL
    var cwd: URL
    var patch: String
}

private struct NativeApplyPatchError: Error {
    var message: String
    var exitCode: Int

    init(_ message: String, exitCode: Int) {
        self.message = message
        self.exitCode = exitCode
    }
}

private struct AffectedPaths {
    var added: [String] = []
    var modified: [String] = []
    var deleted: [String] = []
}

private struct Replacement {
    var startIndex: Int
    var oldLength: Int
    var newLines: [String]
}

private enum PatchHunk {
    case addFile(path: String, contents: String)
    case deleteFile(path: String)
    case updateFile(path: String, movePath: String?, chunks: [UpdateFileChunk])
}

private struct UpdateFileChunk {
    var changeContext: String?
    var oldLines: [String]
    var newLines: [String]
    var isEndOfFile: Bool
}

private enum PatchParser {
    private static let beginPatchMarker = "*** Begin Patch"
    private static let endPatchMarker = "*** End Patch"
    private static let addFileMarker = "*** Add File: "
    private static let deleteFileMarker = "*** Delete File: "
    private static let updateFileMarker = "*** Update File: "
    private static let moveToMarker = "*** Move to: "
    private static let eofMarker = "*** End of File"

    static func parse(_ patch: String) throws -> [PatchHunk] {
        let lines = normalizedLines(patch)
        let body = try checkedBodyLines(lines)
        var remainingIndex = 0
        var lineNumber = 2
        var hunks: [PatchHunk] = []

        while remainingIndex < body.count {
            let parsed = try parseOneHunk(Array(body[remainingIndex...]), lineNumber: lineNumber)
            hunks.append(parsed.hunk)
            remainingIndex += parsed.lineCount
            lineNumber += parsed.lineCount
        }
        return hunks
    }

    private static func normalizedLines(_ patch: String) -> [String] {
        let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        return trimmed.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    private static func checkedBodyLines(_ lines: [String]) throws -> [String] {
        if let body = strictBodyLines(lines) {
            return body
        }

        if lines.count >= 4,
           let first = lines.first,
           let last = lines.last,
           ["<<EOF", "<<'EOF'", "<<\"EOF\""].contains(first),
           last.hasSuffix("EOF"),
           let body = strictBodyLines(Array(lines[1..<lines.count - 1]))
        {
            return body
        }

        if lines.first?.trimmingCharacters(in: .whitespaces) != beginPatchMarker {
            throw ParseError.invalidPatch("The first line of the patch must be '\(beginPatchMarker)'")
        }
        throw ParseError.invalidPatch("The last line of the patch must be '\(endPatchMarker)'")
    }

    private static func strictBodyLines(_ lines: [String]) -> [String]? {
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces) == beginPatchMarker,
              lines.last?.trimmingCharacters(in: .whitespaces) == endPatchMarker
        else {
            return nil
        }
        return Array(lines.dropFirst().dropLast())
    }

    private static func parseOneHunk(_ lines: [String], lineNumber: Int) throws -> (hunk: PatchHunk, lineCount: Int) {
        guard let first = lines.first else {
            throw ParseError.invalidHunk(message: "Unexpected end of patch", lineNumber: lineNumber)
        }

        let firstLine = first.trimmingCharacters(in: .whitespaces)
        if let path = firstLine.removingPrefix(addFileMarker) {
            var contents = ""
            var parsedLines = 1
            for line in lines.dropFirst() {
                guard let lineToAdd = line.removingPrefix("+") else {
                    break
                }
                contents += "\(lineToAdd)\n"
                parsedLines += 1
            }
            return (.addFile(path: path, contents: contents), parsedLines)
        }

        if let path = firstLine.removingPrefix(deleteFileMarker) {
            return (.deleteFile(path: path), 1)
        }

        if let path = firstLine.removingPrefix(updateFileMarker) {
            var index = 1
            var parsedLines = 1
            var movePath: String?
            if index < lines.count, let parsedMovePath = lines[index].removingPrefix(moveToMarker) {
                movePath = parsedMovePath
                index += 1
                parsedLines += 1
            }

            var chunks: [UpdateFileChunk] = []
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    parsedLines += 1
                    continue
                }
                if lines[index].hasPrefix("*") {
                    break
                }

                let parsed = try parseUpdateFileChunk(
                    Array(lines[index...]),
                    lineNumber: lineNumber + parsedLines,
                    allowMissingContext: chunks.isEmpty
                )
                chunks.append(parsed.chunk)
                index += parsed.lineCount
                parsedLines += parsed.lineCount
            }

            guard !chunks.isEmpty else {
                throw ParseError.invalidHunk(message: "Update file hunk for path '\(path)' is empty", lineNumber: lineNumber)
            }
            return (.updateFile(path: path, movePath: movePath, chunks: chunks), parsedLines)
        }

        throw ParseError.invalidHunk(
            message: "'\(firstLine)' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'",
            lineNumber: lineNumber
        )
    }

    private static func parseUpdateFileChunk(
        _ lines: [String],
        lineNumber: Int,
        allowMissingContext: Bool
    ) throws -> (chunk: UpdateFileChunk, lineCount: Int) {
        guard let first = lines.first else {
            throw ParseError.invalidHunk(message: "Update hunk does not contain any lines", lineNumber: lineNumber)
        }

        let changeContext: String?
        let startIndex: Int
        if first == "@@" {
            changeContext = nil
            startIndex = 1
        } else if let context = first.removingPrefix("@@ ") {
            changeContext = context
            startIndex = 1
        } else if allowMissingContext {
            changeContext = nil
            startIndex = 0
        } else {
            throw ParseError.invalidHunk(
                message: "Expected update hunk to start with a @@ context marker, got: '\(first)'",
                lineNumber: lineNumber
            )
        }

        guard startIndex < lines.count else {
            throw ParseError.invalidHunk(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
        }

        var chunk = UpdateFileChunk(changeContext: changeContext, oldLines: [], newLines: [], isEndOfFile: false)
        var parsedLines = 0
        for line in lines.dropFirst(startIndex) {
            if line == eofMarker {
                guard parsedLines > 0 else {
                    throw ParseError.invalidHunk(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
                }
                chunk.isEndOfFile = true
                parsedLines += 1
                break
            }

            if line.isEmpty {
                chunk.oldLines.append("")
                chunk.newLines.append("")
            } else if let value = line.removingPrefix(" ") {
                chunk.oldLines.append(value)
                chunk.newLines.append(value)
            } else if let value = line.removingPrefix("+") {
                chunk.newLines.append(value)
            } else if let value = line.removingPrefix("-") {
                chunk.oldLines.append(value)
            } else {
                guard parsedLines > 0 else {
                    throw ParseError.invalidHunk(
                        message: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)",
                        lineNumber: lineNumber + 1
                    )
                }
                break
            }
            parsedLines += 1
        }

        return (chunk, parsedLines + startIndex)
    }

    enum ParseError: Error {
        case invalidPatch(String)
        case invalidHunk(message: String, lineNumber: Int)

        var userMessage: String {
            switch self {
            case .invalidPatch(let message):
                return "Invalid patch: \(message)"
            case .invalidHunk(let message, let lineNumber):
                return "Invalid patch hunk on line \(lineNumber): \(message)"
            }
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}
#endif
