//
//  SkillStore.swift
//  Chatmice / macai
//
//  Discovers SKILL.md bundles and provides skill.read tool.
//

import Foundation

public struct SkillInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var directory: URL
    public var allowedTools: [String]
    public var model: String?

    public init(name: String, description: String, directory: URL, allowedTools: [String] = [], model: String? = nil) {
        self.name = name
        self.description = description
        self.directory = directory
        self.allowedTools = allowedTools
        self.model = model
    }
}

public protocol SkillCatalog: Sendable {
    func skills() async -> [SkillInfo]
    func read(name: String, path: String?) async throws -> String
    func systemPromptSection() async -> String
}

public actor SkillStore: SkillCatalog {
    public let directories: [URL]

    public init(directories: [URL]? = nil) {
        if let directories {
            self.directories = directories
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let chatmiceDir = appSupport.appendingPathComponent("Chatmice/skills", isDirectory: true)
            let macaiDir = appSupport.appendingPathComponent("macai/skills", isDirectory: true)
            try? fm.createDirectory(at: chatmiceDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: macaiDir, withIntermediateDirectories: true)
            self.directories = [chatmiceDir, macaiDir]
        }
    }

    public func skills() async -> [SkillInfo] {
        let fm = FileManager.default
        var result: [SkillInfo] = []

        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            for entry in entries {
                let rv = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                guard rv?.isDirectory == true else { continue }
                let skillFile = entry.appendingPathComponent("SKILL.md")
                guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let (meta, _) = Self.parseFrontmatter(raw)
                let name = meta["name"] ?? entry.lastPathComponent
                let desc = meta["description"] ?? ""
                let allowed = (meta["allowed-tools"] ?? meta["allowedTools"])?
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map(String.init) ?? []
                result.append(SkillInfo(
                    name: name,
                    description: desc,
                    directory: entry,
                    allowedTools: allowed,
                    model: meta["model"]
                ))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    public func read(name: String, path: String?) async throws -> String {
        let all = await skills()
        guard let s = all.first(where: { $0.name == name || $0.directory.lastPathComponent == name }) else {
            throw ToolError.unknownTool("skill: \(name)")
        }
        let dir = s.directory
        if let path, !path.isEmpty {
            let target = dir.appendingPathComponent(path)
            guard target.standardized.path.hasPrefix(dir.standardized.path) else {
                throw ToolError.invalidArguments("path 必须在 skill 目录内")
            }
            guard let content = try? String(contentsOf: target, encoding: .utf8) else {
                throw ToolError.unknownTool("文件：\(path)")
            }
            return content
        }
        let skillFile = dir.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else {
            throw ToolError.unknownTool("skill：\(name)")
        }
        return Self.parseFrontmatter(raw).body
    }

    public func systemPromptSection() async -> String {
        let list = await skills()
        guard !list.isEmpty else { return "" }
        var lines = [
            "可用技能（skills）。需要某技能时调用 skill.read 工具（参数 name，可选 path）读取完整说明：",
            ""
        ]
        for s in list {
            lines.append("- \(s.name)：\(s.description)（目录 \(s.directory.lastPathComponent)）")
        }
        return lines.joined(separator: "\n")
    }

    static func parseFrontmatter(_ raw: String) -> (meta: [String: String], body: String) {
        guard raw.hasPrefix("---") else { return ([:], raw) }
        let lines = raw.components(separatedBy: "\n")
        guard lines.count > 1 else { return ([:], raw) }
        var meta: [String: String] = [:]
        var endIdx: Int?

        for i in 1..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                endIdx = i
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: .whitespaces)
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                meta[k] = v
            }
        }
        guard let end = endIdx else { return ([:], raw) }
        let bodyLines = lines[(end + 1)...]
        return (meta, bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct SkillTool: AgentTool {
    private let catalog: SkillCatalog

    public init(catalog: SkillCatalog) {
        self.catalog = catalog
    }

    public let definition = ToolDefinition(
        name: "skill.read",
        description: """
        读取一个 skill 的完整说明。参数：name（必填，skill 名或目录名）；
        path（可选，skill 目录内的引用文件相对路径，如 references/api.md）。
        不传 path 返回 SKILL.md 正文（不含 frontmatter）。
        """,
        parameters: .object(properties: [
            "name": .string,
            "path": .string
        ], required: ["name"], additionalProperties: nil)
    )

    public func call(arguments: String, context: ToolContext) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else {
            throw ToolError.invalidArguments("skill.read 参数必须包含 name: string")
        }
        let path = obj["path"] as? String
        return try await catalog.read(name: name, path: path)
    }
}
