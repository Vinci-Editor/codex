//
//  CodexNativeApplyPatch+Types.swift
//  CodexMobileCoreBridge
//
//  Created by Ethan Lipnik.
//

import Foundation

#if os(macOS)
struct NativeApplyPatchRequest {
var workspaceRoot: URL
var cwd: URL
var patch: String
}

struct NativeApplyPatchError: Error {
var message: String
var exitCode: Int

init(_ message: String, exitCode: Int) {
    self.message = message
    self.exitCode = exitCode
}
}

struct AffectedPaths {
var added: [String] = []
var modified: [String] = []
var deleted: [String] = []
}

struct Replacement {
var startIndex: Int
var oldLength: Int
var newLines: [String]
}

enum PatchHunk {
case addFile(path: String, contents: String)
case deleteFile(path: String)
case updateFile(path: String, movePath: String?, chunks: [UpdateFileChunk])
}

struct UpdateFileChunk {
var changeContext: String?
var oldLines: [String]
var newLines: [String]
var isEndOfFile: Bool
}

#endif
