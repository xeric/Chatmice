//
// FileTools.swift
// Chatmice
//
// Foundation-backed file and structured-data tools. Foundation's FileManager,
// Data, and FileHandle already provide the native zero-dependency primitives;
// wrapper libraries add path syntax, not faster I/O.
//
import Foundation

private enum FileToolSupport {
    static let maxReadBytes = 1_048_576
    static let maxOutputCharacters = 100_000

    static func url(path: String, context: ToolContext) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidArguments("path must not be empty") }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: context.cwd).standardizedFileURL
        guard url.isFileURL else { throw ToolError.invalidArguments("path must be a local file URL") }
        return url
    }

    static func object(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("arguments must be a JSON object")
        }
        return object
    }

    static func requiredString(_ key: String, from object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw ToolError.invalidArguments("missing required string: \(key)")
        }
        return value
    }

    static func capped(_ value: String) -> String {
        guard value.count > maxOutputCharacters else { return value }
        return String(value.prefix(maxOutputCharacters)) + "\n[output truncated]"
    }
}

struct ReadFileTool: AgentTool {
    let definition = ToolDefinition(
        name: "read_file",
        description: "Read a UTF-8 text file. Supports optional one-based start_line and end_line bounds.",
        parameters: .object(
            properties: ["path": .string, "start_line": .integer, "end_line": .integer],
            required: ["path"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try FileToolSupport.object(arguments)
        let url = try FileToolSupport.url(path: try FileToolSupport.requiredString("path", from: object), context: context)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= FileToolSupport.maxReadBytes else {
            throw ToolError.executionFailed("File is \(size) bytes; read_file limit is \(FileToolSupport.maxReadBytes) bytes")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let start = max(1, (object["start_line"] as? NSNumber)?.intValue ?? 1)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let end = min(lines.count, (object["end_line"] as? NSNumber)?.intValue ?? lines.count)
        guard start <= end || lines.isEmpty else { return "" }
        return lines.enumerated().compactMap { index, line in
            let number = index + 1
            return (start...end).contains(number) ? "\(number):\(line)" : nil
        }.joined(separator: "\n")
    }
}

struct WriteFileTool: AgentTool {
    let definition = ToolDefinition(
        name: "write_file",
        description: "Create or replace a UTF-8 text file, creating parent directories when needed.",
        parameters: .object(
            properties: ["path": .string, "content": .string],
            required: ["path", "content"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try FileToolSupport.object(arguments)
        let path = try FileToolSupport.requiredString("path", from: object)
        let url = try FileToolSupport.url(path: path, context: context)
        guard let content = object["content"] as? String else {
            throw ToolError.invalidArguments("missing required string: content")
        }
        guard await context.ask("Write file:\n\(url.path)") else {
            throw ToolError.confirmationDenied("User denied file write")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return "Wrote \(content.utf8.count) bytes to \(url.path)"
    }
}

struct EditFileTool: AgentTool {
    let definition = ToolDefinition(
        name: "edit_file",
        description: "Replace an inclusive one-based line range in a UTF-8 text file.",
        parameters: .object(
            properties: ["path": .string, "start_line": .integer, "end_line": .integer, "replacement": .string],
            required: ["path", "start_line", "end_line", "replacement"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try FileToolSupport.object(arguments)
        let url = try FileToolSupport.url(path: try FileToolSupport.requiredString("path", from: object), context: context)
        guard let start = (object["start_line"] as? NSNumber)?.intValue,
              let end = (object["end_line"] as? NSNumber)?.intValue,
              start >= 1, end >= start,
              let replacement = object["replacement"] as? String else {
            throw ToolError.invalidArguments("start_line/end_line must identify a valid inclusive range")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard end <= lines.count else {
            throw ToolError.invalidArguments("line range \(start)-\(end) exceeds file length \(lines.count)")
        }
        guard await context.ask("Edit lines \(start)-\(end) in:\n\(url.path)") else {
            throw ToolError.confirmationDenied("User denied file edit")
        }
        let replacementLines = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.replaceSubrange((start - 1)...(end - 1), with: replacementLines)
        let updated = lines.joined(separator: "\n")
        try Data(updated.utf8).write(to: url, options: .atomic)
        return "Updated lines \(start)-\(end) in \(url.path)"
    }
}

struct ListDirectoryTool: AgentTool {
    let definition = ToolDefinition(
        name: "list_directory",
        description: "List a directory with entry type and byte size. Results are sorted by name.",
        parameters: .object(properties: ["path": .string], required: ["path"], additionalProperties: nil)
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try FileToolSupport.object(arguments)
        let url = try FileToolSupport.url(path: try FileToolSupport.requiredString("path", from: object), context: context)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        let rows = try entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { entry -> String in
                let values = try entry.resourceValues(forKeys: keys)
                return "\(values.isDirectory == true ? "dir" : "file")\t\(values.fileSize ?? 0)\t\(entry.lastPathComponent)"
            }
        return FileToolSupport.capped(rows.joined(separator: "\n"))
    }
}


struct SQLQueryTool: AgentTool {
    let definition = ToolDefinition(
        name: "sql_query",
        description: "Run a read-only SELECT, WITH, PRAGMA, or EXPLAIN query against a local SQLite database.",
        parameters: .object(
            properties: ["database": .string, "query": .string],
            required: ["database", "query"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try FileToolSupport.object(arguments)
        let database = try FileToolSupport.url(
            path: try FileToolSupport.requiredString("database", from: object),
            context: context
        )
        let query = try FileToolSupport.requiredString("query", from: object)
        let verb = query.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace }.uppercased()
        guard ["SELECT", "WITH", "PRAGMA", "EXPLAIN"].contains(verb) else {
            throw ToolError.invalidArguments("sql_query is read-only")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError.executionFailed(String(decoding: errorData, as: UTF8.self))
        }
        return FileToolSupport.capped(String(decoding: data, as: UTF8.self))
    }
}
