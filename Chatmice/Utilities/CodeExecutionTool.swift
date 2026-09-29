//
// CodeExecutionTool.swift
// Chatmice
//
// Sandboxed local Python execution. The process has no network access and can
// only write inside its disposable working directory.
//

import Darwin
import Foundation

private actor SandboxedPythonExecutor {
    private let maxOutputBytes = 100 * 1024

    func run(code: String, timeout: TimeInterval) async throws -> BashOutput {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chatmice-CodeExecution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("main.py")
        try Data(code.utf8).write(to: script, options: .atomic)

        let profile = """
        (version 1)
        (deny default)
        (allow process*)
        (allow sysctl-read)
        (allow mach-lookup)
        (allow file-read*)
        (deny file-read* (subpath "\(escapedProfilePath(FileManager.default.homeDirectoryForCurrentUser.path))"))
        (allow file-write*
            (subpath "\(escapedProfilePath(workspace.path))")
            (literal "/dev/null"))
        (deny network*)
        """

        let python = pythonExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, python, script.path]
        process.currentDirectoryURL = workspace
        process.environment = [
            "HOME": workspace.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": workspace.path,
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        async let stdout = readLimited(output.fileHandleForReading)
        async let stderr = readLimited(errors.fileHandleForReading)
        let pid = process.processIdentifier
        let watchdog = Task.detached {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                kill(pid, SIGTERM)
                try await Task.sleep(nanoseconds: 500_000_000)
                kill(pid, SIGKILL)
            } catch {}
        }

        let outData = await stdout
        let errorData = await stderr
        process.waitUntilExit()
        watchdog.cancel()
        let timedOut = process.terminationReason == .uncaughtSignal
        return BashOutput(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .newlines),
            stderr: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .newlines),
            timedOut: timedOut,
            truncated: outData.count >= maxOutputBytes || errorData.count >= maxOutputBytes
        )
    }

    private func pythonExecutable() -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
    }

    private func escapedProfilePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func readLimited(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    let remaining = max(0, self.maxOutputBytes - data.count)
                    data.append(chunk.prefix(remaining))
                    if data.count >= self.maxOutputBytes { break }
                }
                continuation.resume(returning: data)
            }
        }
    }
}

struct PythonInterpreterTool: AgentTool {
    private let executor = SandboxedPythonExecutor()

    let definition = ToolDefinition(
        name: "python_interpreter",
        description: "Execute Python 3 in a disposable macOS sandbox with network denied, a 30-second default timeout, and capped output.",
        parameters: .object(
            properties: ["code": .string, "timeout_seconds": .integer],
            required: ["code"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String,
              !code.isEmpty else {
            throw ToolError.invalidArguments("python_interpreter requires code: string")
        }
        let timeout = min(120, max(1, (object["timeout_seconds"] as? NSNumber)?.doubleValue ?? 30))
        guard await context.ask("Run sandboxed Python code:\n\(code.prefix(500))") else {
            throw ToolError.confirmationDenied("User denied Python execution")
        }
        return try await executor.run(code: code, timeout: timeout).modelFacingText
    }
}
