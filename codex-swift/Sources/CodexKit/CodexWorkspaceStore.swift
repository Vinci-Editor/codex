import Foundation

public struct CodexWorkspaceRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let bookmarkData: Data?
    public let readOnly: Bool
    public let lastUsedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        rootPath: String,
        bookmarkData: Data?,
        readOnly: Bool,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.readOnly = readOnly
        self.lastUsedAt = lastUsedAt
    }
}

public final class CodexWorkspaceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "CodexKit.Workspaces"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func list() throws -> [CodexWorkspaceRecord] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return try JSONDecoder().decode([CodexWorkspaceRecord].self, from: data)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    @discardableResult
    public func save(
        _ workspace: CodexWorkspace,
        displayName: String? = nil,
        id: String? = nil,
        lastUsedAt: Date = Date()
    ) throws -> CodexWorkspaceRecord {
        let record = CodexWorkspaceRecord(
            id: id ?? workspace.rootURL.path,
            displayName: displayName ?? workspace.rootURL.lastPathComponent,
            rootPath: workspace.rootURL.path,
            bookmarkData: workspace.bookmarkData,
            readOnly: workspace.readOnly,
            lastUsedAt: lastUsedAt
        )
        var records = try list().filter { $0.id != record.id && $0.rootPath != record.rootPath }
        records.insert(record, at: 0)
        try write(records)
        return record
    }

    public func remove(id: String) throws {
        try write(try list().filter { $0.id != id })
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    public func resolve(_ record: CodexWorkspaceRecord) throws -> CodexWorkspace {
        CodexWorkspace(
            rootURL: URL(fileURLWithPath: record.rootPath, isDirectory: true),
            bookmarkData: record.bookmarkData,
            readOnly: record.readOnly
        )
    }

    private func write(_ records: [CodexWorkspaceRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }
}
