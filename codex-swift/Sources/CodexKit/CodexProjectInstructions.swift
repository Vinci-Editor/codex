import Foundation

public struct CodexProjectInstructions: Sendable, Equatable {
    public static let defaultMaxBytes = 32 * 1024
    public static let defaultFilename = "AGENTS.md"
    public static let localOverrideFilename = "AGENTS.override.md"

    public let text: String
    public let sources: [URL]

    public init(text: String, sources: [URL]) {
        self.text = text
        self.sources = sources
    }

    public static func load(
        from rootURL: URL,
        currentDirectoryURL: URL? = nil,
        maxBytes: Int = Self.defaultMaxBytes,
        fileManager: FileManager = .default
    ) throws -> CodexProjectInstructions? {
        guard maxBytes > 0 else {
            return nil
        }

        let root = rootURL.standardizedFileURL
        let currentDirectory = currentDirectoryURL?.standardizedFileURL ?? root
        let searchDirectories = directories(from: root, to: currentDirectory)
        var remainingBytes = maxBytes
        var sources: [URL] = []
        var sections: [String] = []

        for directory in searchDirectories where remainingBytes > 0 {
            guard let source = instructionFile(in: directory, fileManager: fileManager) else {
                continue
            }
            var data = try Data(contentsOf: source)
            if data.count > remainingBytes {
                data = data.prefix(remainingBytes)
            }
            remainingBytes = max(remainingBytes - data.count, 0)

            let text = String(decoding: data, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            sources.append(source)
            sections.append(trimmed)
        }

        guard !sections.isEmpty else {
            return nil
        }

        let currentPath = currentDirectory.path(percentEncoded: false)
        let body = sections.joined(separator: "\n\n")
        let text = """
        # AGENTS.md instructions for \(currentPath)

        <INSTRUCTIONS>
        \(body)
        </INSTRUCTIONS>
        """
        return CodexProjectInstructions(text: text, sources: sources)
    }

    private static func directories(from root: URL, to currentDirectory: URL) -> [URL] {
        let rootPath = normalizedPath(root)
        let currentPath = normalizedPath(currentDirectory)
        guard currentPath == rootPath || currentPath.hasPrefix("\(rootPath)/") else {
            return [root]
        }

        var directories: [URL] = []
        var cursor = currentDirectory
        while true {
            directories.append(cursor)
            if normalizedPath(cursor) == rootPath {
                break
            }
            let parent = cursor.deletingLastPathComponent()
            guard normalizedPath(parent) != normalizedPath(cursor) else {
                break
            }
            cursor = parent
        }
        return directories.reversed()
    }

    private static func instructionFile(in directory: URL, fileManager: FileManager) -> URL? {
        for filename in [localOverrideFilename, defaultFilename] {
            let candidate = directory.appending(path: filename)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
