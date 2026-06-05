//
//  CodexNativeApplyPatch+Parser.swift
//  CodexMobileCoreBridge
//
//  Created by Ethan Lipnik.
//

import Foundation

#if os(macOS)
enum PatchParser {
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

static func normalizedLines(_ patch: String) -> [String] {
    let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return []
    }
    return trimmed.components(separatedBy: "\n").map { line in
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}

static func checkedBodyLines(_ lines: [String]) throws -> [String] {
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

static func strictBodyLines(_ lines: [String]) -> [String]? {
    guard lines.count >= 2,
          lines.first?.trimmingCharacters(in: .whitespaces) == beginPatchMarker,
          lines.last?.trimmingCharacters(in: .whitespaces) == endPatchMarker
    else {
        return nil
    }
    return Array(lines.dropFirst().dropLast())
}

static func parseOneHunk(_ lines: [String], lineNumber: Int) throws -> (hunk: PatchHunk, lineCount: Int) {
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

static func parseUpdateFileChunk(
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
