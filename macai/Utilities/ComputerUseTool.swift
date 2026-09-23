//
//  ComputerUseTool.swift
//  Chatmice / macai
//
//  macOS screen capture tool.
//

import AppKit
import CoreGraphics
import Foundation

public struct ScreenshotTool: AgentTool {
    public init() {}

    public let definition = ToolDefinition(
        name: "computer.screenshot",
        description: "截取当前主屏幕截图，返回 base64 PNG data URL。无需参数。",
        parameters: .object(properties: [:], required: [], additionalProperties: nil)
    )

    public func call(arguments: String, context: ToolContext) async throws -> String {
        let allow = await context.ask("截图当前屏幕以供视觉分析")
        guard allow else {
            throw ToolError.confirmationDenied("用户取消了屏幕截图")
        }

        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw ToolError.executionFailed("截取屏幕失败（请检查是否有屏幕录制权限）")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.executionFailed("转换为 PNG 格式失败")
        }

        let b64 = pngData.base64EncodedString()
        return "data:image/png;base64,\(b64)"
    }
}
