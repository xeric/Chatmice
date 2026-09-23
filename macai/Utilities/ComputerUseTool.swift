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
        description: "Captures a screenshot of the main display and returns a base64 PNG data URL. No parameters required.",
        parameters: .object(properties: [:], required: [], additionalProperties: nil)
    )

    public func call(arguments: String, context: ToolContext) async throws -> String {
        let allow = await context.ask("Take a screenshot of current display for visual analysis")
        guard allow else {
            throw ToolError.confirmationDenied("User denied screen capture")
        }

        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw ToolError.executionFailed("Failed to capture screen (check Screen Recording permissions)")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.executionFailed("Failed to convert image to PNG format")
        }

        let b64 = pngData.base64EncodedString()
        return "data:image/png;base64,\(b64)"
    }
}
