//
//  CodexNativeApplyPatch+Application.swift
//  CodexMobileCoreBridge
//
//  Created by Ethan Lipnik.
//

import Foundation

#if os(macOS)
extension CodexNativeApplyPatch {
static func apply(_ patch: String, workspaceRoot: URL, cwd: URL) throws -> AffectedPaths {
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

static func existingFileURL(rawPath: String, cwd: URL, workspaceRoot: URL) throws -> URL {
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

static func writableURL(rawPath: String, cwd: URL, workspaceRoot: URL) throws -> URL {
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

static func resolve(rawPath: String, cwd: URL) -> URL {
    rawPath.hasPrefix("/")
        ? URL(fileURLWithPath: rawPath)
        : cwd.appending(path: rawPath, directoryHint: .inferFromPath)
}

static func nearestExistingAncestor(_ url: URL) throws -> URL {
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

static func ensureNotDirectory(_ url: URL, displayPath: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        throw NativeApplyPatchError("\(displayPath): path is a directory", exitCode: 1)
    }
}

static func isInsideWorkspace(_ url: URL, root: URL) -> Bool {
    url.path == root.path || url.path.hasPrefix(root.path + "/")
}
}
#endif
