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

    func run(code: String, workspaceRoot: URL, timeout: TimeInterval) async throws -> BashOutput {
        let workspace = workspaceRoot
            .appendingPathComponent(".chatmice", isDirectory: true)
            .appendingPathComponent("python-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("main.py")
        try Data(code.utf8).write(to: script, options: .atomic)

        let resolvedRoot = SandboxProfilePathRules.resolvedRoot(workspaceRoot)
        let rootPath = SandboxProfilePathRules.escaped(resolvedRoot.path)
        let ancestorReadRules = SandboxProfilePathRules.ancestorReadRules(for: resolvedRoot)
        let profile = """
        (version 1)
        (deny default)
        (allow process*)
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
            (subpath "/dev"))
        (allow file-write*
            (subpath "\(rootPath)")
            (literal "/dev/null"))
        (deny network*)
        """

        let python = pythonExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, python, script.path]
        process.currentDirectoryURL = workspaceRoot
        process.environment = [
            "HOME": workspaceRoot.path,
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
        let watchdog = Task.detached { () -> Bool in
            var didTimeout = false
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                didTimeout = true
                kill(pid, SIGTERM)
                try await Task.sleep(nanoseconds: 500_000_000)
                kill(pid, SIGKILL)
            } catch {}
            return didTimeout
        }

        let outData = await stdout
        let errorData = await stderr
        process.waitUntilExit()
        watchdog.cancel()
        let timedOut = await watchdog.value
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
        let output = try await executor.run(
            code: code,
            workspaceRoot: context.cwd,
            timeout: timeout
        )
        guard output.exitCode == 0, !output.timedOut else {
            throw ToolError.executionFailed(output.modelFacingText)
        }
        return output.modelFacingText
    }
}
