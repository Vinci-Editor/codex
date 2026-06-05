import Foundation

public struct CodexProjectSkill: Sendable, Equatable {
    public let name: String
    public let description: String
    public let shortDescription: String?
    public let skillFileURL: URL

    public init(name: String, description: String, shortDescription: String? = nil, skillFileURL: URL) {
        self.name = name
        self.description = description
        self.shortDescription = shortDescription
        self.skillFileURL = skillFileURL
    }
}

public struct CodexProjectSkills: Sendable, Equatable {
    public static let defaultMaxRenderedCharacters = 8 * 1024
    public static let defaultMaxSkillFileBytes = 64 * 1024
    public static let defaultMaxScanDepth = 6
    public static let defaultMaxSkillDirectoriesPerRoot = 2_000
    public static let skillFilename = "SKILL.md"

    public let text: String
    public let skills: [CodexProjectSkill]
    public let roots: [URL]

    public init(text: String, skills: [CodexProjectSkill], roots: [URL]) {
        self.text = text
        self.skills = skills
        self.roots = roots
    }

    public static func load(
        from rootURL: URL,
        currentDirectoryURL: URL? = nil,
        maxRenderedCharacters: Int = Self.defaultMaxRenderedCharacters,
        maxSkillFileBytes: Int = Self.defaultMaxSkillFileBytes,
        maxScanDepth: Int = Self.defaultMaxScanDepth,
        maxSkillDirectoriesPerRoot: Int = Self.defaultMaxSkillDirectoriesPerRoot,
        fileManager: FileManager = .default
    ) throws -> CodexProjectSkills? {
        guard maxRenderedCharacters > 0, maxSkillFileBytes > 0 else {
            return nil
        }

        let root = rootURL.standardizedFileURL
        let currentDirectory = currentDirectoryURL?.standardizedFileURL ?? root
        let searchDirectories = directories(from: root, to: currentDirectory)
        let roots = skillRoots(in: searchDirectories, fileManager: fileManager)
        guard !roots.isEmpty else {
            return nil
        }

        var seenSkillFiles = Set<String>()
        var skills: [CodexProjectSkill] = []
        for root in roots {
            let discovered = discoverSkills(
                under: root,
                maxSkillFileBytes: maxSkillFileBytes,
                maxScanDepth: maxScanDepth,
                maxSkillDirectoriesPerRoot: maxSkillDirectoriesPerRoot,
                fileManager: fileManager
            )
            for skill in discovered {
                let key = normalizedPath(skill.skillFileURL)
                guard seenSkillFiles.insert(key).inserted else {
                    continue
                }
                skills.append(skill)
            }
        }

        guard !skills.isEmpty else {
            return nil
        }

        skills.sort {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return normalizedPath($0.skillFileURL) < normalizedPath($1.skillFileURL)
        }

        let text = render(
            skills: skills,
            currentDirectory: currentDirectory,
            maxRenderedCharacters: maxRenderedCharacters
        )
        return CodexProjectSkills(text: text, skills: skills, roots: roots)
    }

    private static func skillRoots(in directories: [URL], fileManager: FileManager) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        for directory in directories {
            for relativeRoot in [".codex/skills", ".agents/skills"] {
                let root = directory.appending(path: relativeRoot, directoryHint: .isDirectory)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }
                let key = normalizedPath(root)
                if seen.insert(key).inserted {
                    roots.append(root)
                }
            }
        }
        return roots
    }

    private static func discoverSkills(
        under root: URL,
        maxSkillFileBytes: Int,
        maxScanDepth: Int,
        maxSkillDirectoriesPerRoot: Int,
        fileManager: FileManager
    ) -> [CodexProjectSkill] {
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var visitedDirectories = Set([normalizedPath(root)])
        var skills: [CodexProjectSkill] = []

        while !queue.isEmpty, visitedDirectories.count <= maxSkillDirectoriesPerRoot {
            let (directory, depth) = queue.removeFirst()
            guard depth <= maxScanDepth else {
                continue
            }

            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]) else {
                    continue
                }
                if values.isDirectory == true || values.isSymbolicLink == true {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        continue
                    }
                    guard depth < maxScanDepth else {
                        continue
                    }
                    let key = normalizedPath(entry)
                    if visitedDirectories.count < maxSkillDirectoriesPerRoot,
                       visitedDirectories.insert(key).inserted {
                        queue.append((entry, depth + 1))
                    }
                    continue
                }

                guard values.isRegularFile == true, entry.lastPathComponent == skillFilename else {
                    continue
                }
                if let skill = try? parseSkillFile(entry, maxSkillFileBytes: maxSkillFileBytes) {
                    skills.append(skill)
                }
            }
        }

        return skills
    }

    private static func parseSkillFile(_ url: URL, maxSkillFileBytes: Int) throws -> CodexProjectSkill? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else {
            return nil
        }
        let limitedData = data.count > maxSkillFileBytes ? data.prefix(maxSkillFileBytes) : data
        let text = String(decoding: limitedData, as: UTF8.self)
        let frontmatter = parseFrontmatter(text)
        let directoryName = url.deletingLastPathComponent().lastPathComponent
        let name = frontmatter.name ?? directoryName
        guard !name.isEmpty else {
            return nil
        }
        return CodexProjectSkill(
            name: name,
            description: frontmatter.description ?? "",
            shortDescription: frontmatter.shortDescription,
            skillFileURL: url
        )
    }

    private static func parseFrontmatter(_ text: String) -> SkillFrontmatter {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let endRange = normalized.dropFirst(4).range(of: "\n---") else {
            return SkillFrontmatter()
        }

        let body = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound]
        var frontmatter = SkillFrontmatter()
        var inMetadata = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            if trimmed == "metadata:" {
                inMetadata = true
                continue
            }
            if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                inMetadata = false
            }
            if inMetadata, let value = scalarValue(in: trimmed, key: "short-description") {
                frontmatter.shortDescription = value
                continue
            }
            if let value = scalarValue(in: trimmed, key: "name") {
                frontmatter.name = value
            } else if let value = scalarValue(in: trimmed, key: "description") {
                frontmatter.description = value
            }
        }
        return frontmatter
    }

    private static func scalarValue(in line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else {
            return nil
        }
        let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return stripBalancedQuotes(String(value))
    }

    private static func stripBalancedQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func render(
        skills: [CodexProjectSkill],
        currentDirectory: URL,
        maxRenderedCharacters: Int
    ) -> String {
        var lines: [String] = [
            "## Skills",
            "A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of project skills available in this Vinci session. Each entry includes a name, description, and file path so you can open the source for full instructions when using a specific skill.",
            "### Available skills",
        ]
        var usedCharacters = lines.reduce(0) { $0 + $1.count + 1 }
        var omitted = 0
        for skill in skills {
            let description = skill.shortDescription ?? skill.description
            let line: String
            if description.isEmpty {
                line = "- \(skill.name): (file: \(skill.skillFileURL.path(percentEncoded: false)))"
            } else {
                line = "- \(skill.name): \(description) (file: \(skill.skillFileURL.path(percentEncoded: false)))"
            }
            if usedCharacters + line.count + 1 > maxRenderedCharacters {
                omitted += 1
                continue
            }
            usedCharacters += line.count + 1
            lines.append(line)
        }
        if omitted > 0 {
            let noun = omitted == 1 ? "skill" : "skills"
            lines.append("- \(omitted) additional \(noun) omitted from this bounded skills list.")
        }
        lines.append("### How to use skills")
        lines.append(skillsHowToUse)

        return """
        # Codex skills for \(currentDirectory.path(percentEncoded: false))

        <skills_instructions>
        \(lines.joined(separator: "\n"))
        </skills_instructions>
        """
    }

    private static let skillsHowToUse = """
    - Discovery: The list above is the skills available in this session (name + description + file path). Skill bodies live on disk at the listed paths.
    - Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
    - Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.
    - How to use a skill (progressive disclosure):
      1) After deciding to use a skill, open its `SKILL.md`. Read only enough to follow the workflow.
      2) When `SKILL.md` references relative paths (e.g., `scripts/foo.py`), resolve them relative to the skill directory listed above first, and only consider other paths if needed.
      3) If `SKILL.md` points to extra folders such as `references/`, load only the specific files needed for the request; don't bulk-load everything.
      4) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
      5) If `assets/` or templates exist, reuse them instead of recreating from scratch.
    - Coordination and sequencing:
      - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
      - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.
    - Context hygiene:
      - Keep context small: summarize long sections instead of pasting them; only load extra files when needed.
      - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked.
      - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.
    - Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.
    """

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

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private struct SkillFrontmatter {
        var name: String?
        var description: String?
        var shortDescription: String?
    }
}
