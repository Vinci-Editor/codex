//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    func appendToolOutput(call: CodexToolCall, result: CodexToolResult) {
        history.append(CodexMobileCoreBridge.toolOutput(
            callID: call.callID,
            output: result.responseOutput?.jsonValue ?? result.output,
            success: result.success,
            custom: call.kind == .custom,
            name: call.name
        ))
    }

    static func decodeArguments(_ arguments: String) throws -> [String: Any] {
        let data = Data(arguments.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        return value as? [String: Any] ?? [:]
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

    static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case let value as Int:
            return value != 0
        default:
            return false
        }
    }


    static func message(role: String, textType: String, text: String) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": [["type": textType, "text": text]],
        ]
    }

    static func resolveExistingWorkspaceURL(root: URL, rawPath: String) throws -> URL {
        try resolveWorkspaceURL(root: root, rawPath: rawPath, mustExist: true)
    }

    static func resolveWorkspaceURL(root: URL, rawPath: String, mustExist: Bool) throws -> URL {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL
        if rawPath.isEmpty || rawPath == "." {
            candidate = rootURL
        } else if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = rootURL.appending(path: rawPath, directoryHint: .inferFromPath)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard !mustExist || FileManager.default.fileExists(atPath: resolved.path) else {
            throw CodexSessionError.workspacePathError("\(rawPath): no such file or directory")
        }
        guard isInsideWorkspace(url: resolved, root: rootURL) else {
            throw CodexSessionError.workspacePathError("\(rawPath): escapes workspace")
        }
        return resolved
    }

    static func listDirectory(root: URL, target: URL, depth: Int) throws -> [String] {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexSessionError.workspacePathError("\(target.path): not a directory")
        }

        var results: [String] = []
        try collectDirectoryEntries(root: rootURL, directory: target, remainingDepth: depth, results: &results)
        return results.sorted()
    }

    static func collectDirectoryEntries(
        root: URL,
        directory: URL,
        remainingDepth: Int,
        results: inout [String]
    ) throws {
        guard remainingDepth > 0 else {
            return
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            let resolved = entry.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideWorkspace(url: resolved, root: root) else {
                continue
            }
            let relative = relativeWorkspacePath(root: root, url: resolved)
            let isDirectory = values.isDirectory == true
            results.append(isDirectory ? "\(relative)/" : relative)
            if isDirectory && values.isSymbolicLink != true {
                try collectDirectoryEntries(
                    root: root,
                    directory: resolved,
                    remainingDepth: remainingDepth - 1,
                    results: &results
                )
            }
        }
    }

    static func searchFiles(
        root: URL,
        target: URL,
        query: String,
        caseSensitive: Bool,
        limit: Int
    ) throws -> [String] {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls: [URL]

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: target,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = [target]
        }

        let needle = caseSensitive ? query : query.lowercased()
        var matches: [String] = []

        for url in urls {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideWorkspace(url: resolved, root: rootURL) else { continue }
            if let fileSize = values.fileSize, fileSize > 2_000_000 { continue }
            guard let text = try? String(contentsOf: resolved, encoding: .utf8) else { continue }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let haystack = caseSensitive ? String(line) : String(line).lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append("\(relativeWorkspacePath(root: rootURL, url: resolved)):\(index + 1): \(line)")
                if matches.count >= limit {
                    return matches
                }
            }
        }

        return matches
    }

    static func relativeWorkspacePath(root: URL, url: URL) -> String {
        url.path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func imageDataURL(for url: URL, detail: String?) throws -> (dataURL: String, detail: String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > viewImageMaxBytes {
            throw CodexSessionError.workspacePathError(
                "\(url.lastPathComponent): image is too large (\(fileSize) bytes)"
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): unsupported image file")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let originalMaxDimension = max(width, height)
        guard originalMaxDimension > 0 else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): image has no readable dimensions")
        }

        let usesOriginal = detail == "original"
        let maxPixelDimension = usesOriginal
            ? originalMaxDimension
            : min(originalMaxDimension, viewImageHighMaxPixelDimension)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not decode image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not create image output")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CodexSessionError.workspacePathError("\(url.lastPathComponent): could not encode image")
        }

        let encoded = (output as Data).base64EncodedString()
        return ("data:image/png;base64,\(encoded)", usesOriginal ? "original" : "high")
    }

    static func isInsideWorkspace(url: URL, root: URL) -> Bool {
        let path = url.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
