//
//  CodexNativeApplyPatch+Replacement.swift
//  CodexMobileCoreBridge
//
//  Created by Ethan Lipnik.
//

import Foundation

#if os(macOS)
extension CodexNativeApplyPatch {
static func deriveNewContents(original: String, path: String, chunks: [UpdateFileChunk]) throws -> String {
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

static func computeReplacements(
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

static func seekSequence(_ lines: [String], pattern: [String], start: Int, eof: Bool) -> Int? {
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

static func firstMatch(
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

static func trimEnd(_ value: String) -> String {
    var result = value
    while let last = result.unicodeScalars.last, CharacterSet.whitespaces.contains(last) {
        result.removeLast()
    }
    return result
}

static func normalizePunctuation(_ value: String) -> String {
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
}
#endif
