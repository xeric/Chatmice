//
//  BashExecutor.swift
//  Chatmice
//
//  Local command execution with process isolation, timeout watchdog, and confirmation.
//

import Darwin
import Foundation
enum BashApprovalMode: String, CaseIterable, Identifiable {
    case alwaysAsk
    case currentSession = "currentChat"
    case alwaysAllow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysAsk: return "Always Ask"
        case .currentSession: return "This Session"
        case .alwaysAllow: return "Always Allow"
        }
    }

    var description: String {
        switch self {
        case .alwaysAsk:
            return "Require approval before every Bash command."
        case .currentSession:
            return "Approve the first Bash command, then allow commands until Chatmice quits."
        case .alwaysAllow:
            return "Allow Bash commands automatically throughout Chatmice."
        }
    }
}

public struct BashOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let truncated: Bool

    public var modelFacingText: String {
        var lines: [String] = []
        if !stdout.isEmpty { lines.append(stdout) }
        if !stderr.isEmpty { lines.append("[stderr] \(stderr)") }
        if timedOut { lines.append("[timed out]") }
        if truncated { lines.append("[output truncated]") }
        lines.append("[exit code: \(exitCode)]")
        return lines.joined(separator: "\n")
    }
}

enum SandboxProfilePathRules {
    static func resolvedRoot(_ url: URL) -> URL {
        guard let resolved = Darwin.realpath(url.path, nil) else {
            return url.standardizedFileURL
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func ancestorReadRules(for root: URL) -> String {
        var ancestors: [String] = []
        var current = root.deletingLastPathComponent()
        while current.path != "/" {
            ancestors.append(current.path)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return ancestors.reversed()
            .map { "(literal \"\(escaped($0))\")" }
            .joined(separator: "\n            ")
    }
}

public actor BashExecutor {
    public var maxOutputBytes: Int

    public init(maxOutputBytes: Int = 50 * 1024) {
        self.maxOutputBytes = maxOutputBytes
    }

    public func run(
        command: String,
        cwd: URL,
        workspaceRoot: URL,
        timeout: TimeInterval = 120
    ) async -> BashOutput {
        let temporaryDirectory = workspaceRoot.appendingPathComponent(".chatmice/tmp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return BashOutput(
                exitCode: -1,
                stdout: "",
                stderr: "failed to prepare workspace: \(error.localizedDescription)",
                timedOut: false,
                truncated: false
            )
        }

        let resolvedRoot = SandboxProfilePathRules.resolvedRoot(workspaceRoot)
        let rootPath = SandboxProfilePathRules.escaped(resolvedRoot.path)
        let ancestorReadRules = SandboxProfilePathRules.ancestorReadRules(for: resolvedRoot)
        let profile = """
        (version 1)
        (deny default)
        (allow process*)
        (allow network*)
        (allow sysctl-read)
        (allow mach-lookup)
        (allow file-read*
            (literal "/")
            \(ancestorReadRules)
            (subpath "\(rootPath)")
            (subpath "/System")
            (subpath "/usr")
            (subpath "/bin")
            (subpath "/sbin")
            (subpath "/opt/homebrew")
            (subpath "/usr/local")
            (subpath "/private/etc")
            (subpath "/Library/Apple")
            (subpath "/Library/Developer")
            (subpath "/Applications/Xcode.app")
            (subpath "/dev"))
        (allow file-write*
            (subpath "\(rootPath)")
            (literal "/dev/null"))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/bash", "--noprofile", "--norc", "-c", command]
        process.currentDirectoryURL = cwd
        process.environment = [
            "HOME": workspaceRoot.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TERM": "dumb",
            "TMPDIR": temporaryDirectory.path,
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return BashOutput(
                exitCode: -1,
                stdout: "",
                stderr: "failed to launch: \(error.localizedDescription)",
                timedOut: false,
                truncated: false
            )
        }

        async let outTask = self.readLimited(outPipe, max: maxOutputBytes)
        async let errTask = self.readLimited(errPipe, max: maxOutputBytes)

        let pid = process.processIdentifier
        let watchdog = Task.detached { () -> Bool in
            var didTimeout = false
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                didTimeout = true
                kill(pid, SIGTERM)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                kill(pid, SIGKILL)
            } catch {}
            return didTimeout
        }

        let outData = await outTask
        let errData = await errTask
        process.waitUntilExit()
        watchdog.cancel()
        let timedOut = await watchdog.value

        var out = String(data: outData, encoding: .utf8) ?? ""
        var err = String(data: errData, encoding: .utf8) ?? ""
        while out.hasSuffix("\n") { out.removeLast() }
        while err.hasSuffix("\n") { err.removeLast() }

        return BashOutput(
            exitCode: process.terminationStatus,
            stdout: out,
            stderr: err,
            timedOut: timedOut,
            truncated: outData.count >= maxOutputBytes || errData.count >= maxOutputBytes
        )
    }

    private func readLimited(_ pipe: Pipe, max: Int) async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > max {
                        data = data.prefix(max)
                        break
                    }
                }
                cont.resume(returning: data)
            }
        }
    }
}

public struct BashTool: AgentTool {
    private let executor: BashExecutor

    public init(executor: BashExecutor = BashExecutor()) {
        self.executor = executor
    }

    public let definition = ToolDefinition(
        name: "bash",
        description: """
        Execute a bash command inside the current workspace's macOS sandbox. Returns stdout, stderr,
        and exit code. Parameters: command (required, full command string); workdir (optional,
        workspace-contained working directory); timeout_seconds (optional, default 120).
        """,
        parameters: .object(properties: [
            "command": .string,
            "workdir": .string,
            "timeout_seconds": .integer
        ], required: ["command"], additionalProperties: nil)
    )

    public func call(arguments: String, context: ToolContext) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String, !command.isEmpty else {
            throw ToolError.invalidArguments("bash arguments must contain command: string")
        }
        let workdir: URL
        do {
            workdir = try WorkspacePathPolicy.containedURL(
                for: obj["workdir"] as? String ?? ".",
                root: context.cwd
            )
        } catch {
            throw ToolError.invalidArguments(error.localizedDescription)
        }
        let timeout = TimeInterval((obj["timeout_seconds"] as? NSNumber)?.intValue ?? 120)

        let allow = await context.ask("Execute command:\n\(command.prefix(300))")
        guard allow else {
            throw ToolError.confirmationDenied("User denied command execution")
        }

        let output = await executor.run(
            command: command,
            cwd: workdir,
            workspaceRoot: context.cwd,
            timeout: timeout
        )
        guard output.exitCode == 0, !output.timedOut else {
            throw ToolError.executionFailed(output.modelFacingText)
        }
        return output.modelFacingText
    }
}
