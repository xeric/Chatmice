//
//  BashExecutor.swift
//  Chatmice / macai
//
//  Local command execution with process isolation, timeout watchdog, and confirmation.
//

import Foundation

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

public actor BashExecutor {
    public var maxOutputBytes: Int

    public init(maxOutputBytes: Int = 50 * 1024) {
        self.maxOutputBytes = maxOutputBytes
    }

    public func run(command: String, cwd: URL? = nil, timeout: TimeInterval = 120) async -> BashOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return BashOutput(exitCode: -1,
                               stdout: "",
                               stderr: "failed to launch: \(error.localizedDescription)",
                               timedOut: false, truncated: false)
        }

        async let outTask = self.readLimited(outPipe, max: maxOutputBytes)
        async let errTask = self.readLimited(errPipe, max: maxOutputBytes)

        let pid = process.processIdentifier
        let watchdog = Task.detached {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                kill(pid, SIGTERM)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                kill(pid, SIGKILL)
            } catch {}
        }

        let outData = await outTask
        let errData = await errTask
        process.waitUntilExit()
        watchdog.cancel()
        let timedOut = process.terminationReason == .uncaughtSignal

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
        在本地执行 bash 命令（/bin/bash -lc）。返回 stdout/stderr/退出码。
        参数：command（必填，完整命令字符串）；workdir（可选，工作目录绝对路径）；
        timeout_seconds（可选，默认 120）。
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
            throw ToolError.invalidArguments("bash 参数必须包含 command: string")
        }
        let workdir = (obj["workdir"] as? String).flatMap { URL(fileURLWithPath: $0) }
        let timeout = TimeInterval((obj["timeout_seconds"] as? NSNumber)?.intValue ?? 120)

        let allow = await context.ask("执行命令：\n\(command.prefix(300))")
        guard allow else {
            throw ToolError.confirmationDenied("用户取消执行命令")
        }

        let output = await executor.run(command: command, cwd: workdir ?? context.cwd, timeout: timeout)
        return output.modelFacingText
    }
}
