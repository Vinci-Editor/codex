import Foundation

public struct CodexWorkspace: Sendable, Equatable {
    public let rootURL: URL
    public let bookmarkData: Data?
    public let readOnly: Bool

    public init(rootURL: URL, bookmarkData: Data? = nil, readOnly: Bool = false) {
        self.rootURL = rootURL
        self.bookmarkData = bookmarkData
        self.readOnly = readOnly
    }

    public static func appContainer(named name: String = "CodexWorkspace") throws -> CodexWorkspace {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CodexWorkspace(rootURL: root)
    }

    public static func securityScopedFolder(url: URL, readOnly: Bool = false) throws -> CodexWorkspace {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = readOnly
            ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            : [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        return CodexWorkspace(rootURL: url, bookmarkData: bookmark, readOnly: readOnly)
    }

    public func withSecurityScope<T>(_ operation: (URL) throws -> T) throws -> T {
        var stale = false
        let url: URL
        if let bookmarkData {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } else {
            url = rootURL
        }

        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(url)
    }
}
