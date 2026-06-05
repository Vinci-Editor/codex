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
    final class CodexJailedBashFileSystem: @unchecked Sendable, BashFilesystem {
        private let rootURL: URL
        private let rootPath: String
        private let fileManager = FileManager.default
        private let lock = NSLock()
        private var commandStubs = Set<String>()

        init(rootURL: URL) {
            self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            self.rootPath = self.rootURL.path
        }

        func seedCommandStub(named name: String) {
            lock.lock()
            commandStubs.insert("/bin/\(name)")
            commandStubs.insert("/usr/bin/\(name)")
            lock.unlock()
        }

        func readFile(path: String, relativeTo: String) throws -> Data {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return Data()
            }
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind != .directory else {
                throw FilesystemError.isDirectory(normalized)
            }
            let url = try urlForExistingPath(normalized)
            do {
                return try Data(contentsOf: url)
            } catch {
                throw FilesystemError.ioError("cannot read \(normalized): \(error.localizedDescription)")
            }
        }

        func writeFile(path: String, content: Data, relativeTo: String) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            if fileExists(path: normalized, relativeTo: "/") {
                let info = try fileInfo(path: normalized, relativeTo: "/")
                guard info.kind != .directory else {
                    throw FilesystemError.isDirectory(normalized)
                }
                _ = try urlForExistingPath(normalized)
            }
            try ensureWritableParent(for: normalized)
            let url = try url(forNormalizedPath: normalized)
            do {
                try content.write(to: url)
            } catch {
                throw FilesystemError.ioError("cannot write \(normalized): \(error.localizedDescription)")
            }
        }

        func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard normalized != "/" else {
                throw FilesystemError.invalidPath(normalized)
            }
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            guard fileExists(path: normalized, relativeTo: "/") else {
                if force {
                    return
                }
                throw FilesystemError.notFound(normalized)
            }
            let info = try fileInfo(path: normalized, relativeTo: "/")
            if info.kind == .directory && !recursive {
                let entries = try listDirectory(path: normalized, relativeTo: "/")
                if !entries.isEmpty {
                    throw FilesystemError.directoryNotEmpty(normalized)
                }
            }
            let url = try urlForExistingPath(normalized)
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw FilesystemError.ioError("cannot delete \(normalized): \(error.localizedDescription)")
            }
        }

        func fileExists(path: String, relativeTo: String) -> Bool {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return true
            }
            guard let url = try? url(forNormalizedPath: normalized) else {
                return false
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return false
            }
            return (try? ensureResolvedURLIsInsideJail(url, normalizedPath: normalized)) != nil
        }

        func isDirectory(path: String, relativeTo: String) -> Bool {
            (try? fileInfo(path: path, relativeTo: relativeTo).kind) == .directory
        }

        func listDirectory(path: String, relativeTo: String) throws -> [String] {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind == .directory else {
                throw FilesystemError.notDirectory(normalized)
            }
            let url = try urlForExistingPath(normalized)
            do {
                return try fileManager.contentsOfDirectory(atPath: url.path).sorted()
            } catch {
                throw FilesystemError.ioError("cannot list \(normalized): \(error.localizedDescription)")
            }
        }

        func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard normalized != "/" else {
                return
            }
            if fileExists(path: normalized, relativeTo: "/") {
                guard isDirectory(path: normalized, relativeTo: "/") else {
                    throw FilesystemError.notDirectory(normalized)
                }
                return
            }
            if recursive {
                try ensureNearestExistingAncestorIsInsideJail(for: normalized)
            } else {
                try ensureWritableParent(for: normalized)
            }
            let url = try url(forNormalizedPath: normalized)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
            } catch {
                throw FilesystemError.ioError("cannot create directory \(normalized): \(error.localizedDescription)")
            }
        }

        func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            if isCommandStub(normalized) {
                return FileInfo(path: normalized, kind: .file, size: 0)
            }
            let url = try url(forNormalizedPath: normalized)
            guard fileManager.fileExists(atPath: url.path) else {
                throw FilesystemError.notFound(normalized)
            }
            _ = try ensureResolvedURLIsInsideJail(url, normalizedPath: normalized)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                return FileInfo(path: normalized, kind: .symlink, size: target.utf8.count)
            }
            if values.isDirectory == true {
                let count = (try? fileManager.contentsOfDirectory(atPath: url.path).count) ?? 0
                return FileInfo(path: normalized, kind: .directory, size: count)
            }
            return FileInfo(path: normalized, kind: .file, size: values.fileSize ?? 0)
        }

        func createSymlink(_ target: String, at path: String, relativeTo: String) throws {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.permissionDenied(normalized)
            }
            try ensureWritableParent(for: normalized)
            let url = try url(forNormalizedPath: normalized)
            let hostTarget: String
            if target.hasPrefix("/") {
                hostTarget = try self.url(forNormalizedPath: normalizePath(target, relativeTo: "/")).path
            } else {
                hostTarget = target
            }
            do {
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: hostTarget)
            } catch {
                throw FilesystemError.ioError("cannot create symlink \(normalized): \(error.localizedDescription)")
            }
        }

        func readlink(_ path: String, relativeTo: String) throws -> String {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            guard !isCommandStub(normalized) else {
                throw FilesystemError.invalidPath(normalized)
            }
            let url = try url(forNormalizedPath: normalized)
            guard fileManager.fileExists(atPath: url.path) else {
                throw FilesystemError.notFound(normalized)
            }
            do {
                let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                guard target.hasPrefix(rootPath + "/") || target == rootPath else {
                    return target
                }
                let relative = target.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? "/" : "/\(relative)"
            } catch {
                throw FilesystemError.ioError("cannot readlink \(normalized): \(error.localizedDescription)")
            }
        }

        func walk(path: String, relativeTo: String) throws -> [String] {
            let normalized = normalizePath(path, relativeTo: relativeTo)
            let info = try fileInfo(path: normalized, relativeTo: "/")
            guard info.kind == .directory else {
                return [normalized]
            }
            var result = [normalized]
            for name in try listDirectory(path: normalized, relativeTo: "/") {
                let child = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
                result.append(contentsOf: try walk(path: child, relativeTo: "/"))
            }
            return result
        }

        func normalizePath(_ path: String, relativeTo: String) -> String {
            VirtualPath.normalize(path, relativeTo: relativeTo)
        }

        func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
            let normalizedPattern = VirtualPath.normalize(pattern, relativeTo: relativeTo)
            let components = normalizedPattern.split(separator: "/").map(String.init)
            guard !components.isEmpty else {
                return fileExists(path: "/", relativeTo: "/") ? ["/"] : []
            }

            var results: [String] = []
            func descend(path: String, remaining: ArraySlice<String>) {
                guard let segment = remaining.first else {
                    if fileExists(path: path, relativeTo: "/") {
                        results.append(path)
                    }
                    return
                }

                guard isDirectory(path: path, relativeTo: "/") else {
                    return
                }

                if !segment.contains("*") && !segment.contains("?") && !segment.contains("[") {
                    let child = path == "/" ? "/\(segment)" : "\(path)/\(segment)"
                    descend(path: child, remaining: remaining.dropFirst())
                    return
                }

                guard let entries = try? listDirectory(path: path, relativeTo: "/") else {
                    return
                }
                for name in entries {
                    if !dotglob && !segment.hasPrefix(".") && name.hasPrefix(".") {
                        continue
                    }
                    if VirtualFileSystem.globMatch(name: name, pattern: segment, extglob: extglob) {
                        let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
                        descend(path: child, remaining: remaining.dropFirst())
                    }
                }
            }

            descend(path: "/", remaining: ArraySlice(components))
            return Array(Set(results)).sorted()
        }

        private func isCommandStub(_ normalizedPath: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return commandStubs.contains(normalizedPath)
        }

        private func url(forNormalizedPath normalizedPath: String) throws -> URL {
            let normalizedPath = VirtualPath.normalize(normalizedPath, relativeTo: "/")
            let url = normalizedPath == "/"
                ? rootURL
                : rootURL.appendingPathComponent(String(normalizedPath.dropFirst()))
            let standardized = url.standardizedFileURL
            guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
                throw FilesystemError.permissionDenied(normalizedPath)
            }
            return standardized
        }

        private func urlForExistingPath(_ normalizedPath: String) throws -> URL {
            let url = try url(forNormalizedPath: normalizedPath)
            _ = try ensureResolvedURLIsInsideJail(url, normalizedPath: normalizedPath)
            return url
        }

        private func ensureResolvedURLIsInsideJail(_ url: URL, normalizedPath: String) throws -> URL {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
                throw FilesystemError.permissionDenied(normalizedPath)
            }
            return resolved
        }

        private func ensureWritableParent(for normalizedPath: String) throws {
            let parent = VirtualPath.dirname(normalizedPath)
            guard isDirectory(path: parent, relativeTo: "/") else {
                throw FilesystemError.notFound(parent)
            }
            let parentURL = try url(forNormalizedPath: parent)
            _ = try ensureResolvedURLIsInsideJail(parentURL, normalizedPath: parent)
        }

        private func ensureNearestExistingAncestorIsInsideJail(for normalizedPath: String) throws {
            var ancestor = VirtualPath.dirname(normalizedPath)
            while ancestor != "/" && !fileExists(path: ancestor, relativeTo: "/") {
                ancestor = VirtualPath.dirname(ancestor)
            }
            guard isDirectory(path: ancestor, relativeTo: "/") else {
                throw FilesystemError.notDirectory(ancestor)
            }
            let ancestorURL = try url(forNormalizedPath: ancestor)
            _ = try ensureResolvedURLIsInsideJail(ancestorURL, normalizedPath: ancestor)
        }
    }
}
#endif
