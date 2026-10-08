//
//  ComputerUseTool.swift
//  Chatmice
//
//  macOS screen capture tool.
//

import AppKit
import CoreGraphics
import Foundation

enum ComputerUsePermissions {
    static var canRecordScreen: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var canControlComputer: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options =
            [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    private static func openPrivacySettings(anchor: String) {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}

struct EncodedScreenshot {
    let data: Data
    let width: Int
    let height: Int
    let quality: CGFloat
}

enum ScreenshotImageEncoder {
    static let maximumDimension = 2_048
    static let maximumBytes = 750 * 1_024

    private static let minimumDimension = 768
    private static let qualitySteps: [CGFloat] = [0.88, 0.80, 0.72, 0.64, 0.54, 0.44]

    static func encode(_ image: CGImage) throws -> EncodedScreenshot {
        var dimensionLimit = min(max(image.width, image.height), maximumDimension)

        while true {
            let resized = try resize(image, maximumDimension: dimensionLimit)
            for quality in qualitySteps {
                let rep = NSBitmapImageRep(cgImage: resized)
                guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                    continue
                }
                if data.count <= maximumBytes {
                    return EncodedScreenshot(
                        data: data,
                        width: resized.width,
                        height: resized.height,
                        quality: quality
                    )
                }
            }

            guard dimensionLimit > minimumDimension else { break }
            dimensionLimit = max(minimumDimension, Int((CGFloat(dimensionLimit) * 0.78).rounded(.down)))
        }

        throw ToolError.executionFailed(
            "Screenshot could not be compressed below \(maximumBytes / 1_024) KB"
        )
    }

    private static func resize(_ image: CGImage, maximumDimension: Int) throws -> CGImage {
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard width != image.width || height != image.height else { return image }

        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ToolError.executionFailed("Failed to create screenshot image context")
        }
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = bitmap.makeImage() else {
            throw ToolError.executionFailed("Failed to resize screenshot")
        }
        return resized
    }
}

public struct ScreenshotTool: AgentTool {
    public init() {}

    public let definition = ToolDefinition(
        name: "computer.screenshot",
        description:
            "Captures a screenshot of the main display and returns a size-bounded JPEG data URL for visual analysis. No parameters required.",
        parameters: .object(properties: [:], required: [], additionalProperties: nil)
    )

    public func call(arguments: String, context: ToolContext) async throws -> String {
        let allow = await context.ask("Take a screenshot of current display for visual analysis")
        guard allow else {
            throw ToolError.confirmationDenied("User denied screen capture")
        }

        guard ComputerUsePermissions.canRecordScreen,
            let image = CGDisplayCreateImage(CGMainDisplayID())
        else {
            throw ToolError.executionFailed(
                "Screen Recording permission is required in System Settings > Privacy & Security > Screen Recording"
            )
        }

        let encoded = try ScreenshotImageEncoder.encode(image)
        let quality = String(format: "%.2f", encoded.quality)
        AppLogger.shared.info(
            "computer.screenshot encoded width=\(encoded.width) height=\(encoded.height) bytes=\(encoded.data.count) quality=\(quality)"
        )
        return "data:image/jpeg;base64,\(encoded.data.base64EncodedString())"
    }
}

private enum ComputerInputSupport {
    static func requireAccessibility() throws {
        guard ComputerUsePermissions.canControlComputer else {
            throw ToolError.executionFailed(
                "Accessibility permission is required in System Settings > Privacy & Security > Accessibility"
            )
        }
    }

    static func object(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ToolError.invalidArguments("arguments must be a JSON object")
        }
        return object
    }

    static func keyCode(_ key: String) -> CGKeyCode? {
        [
            "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ][key.lowercased()]
    }
}

struct MouseClickTool: AgentTool {
    let definition = ToolDefinition(
        name: "mouse_click",
        description: "Click an absolute screen coordinate after user approval.",
        parameters: .object(
            properties: ["x": .number, "y": .number, "button": .string],
            required: ["x", "y"],
            additionalProperties: nil
        )
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try ComputerInputSupport.object(arguments)
        guard let x = (object["x"] as? NSNumber)?.doubleValue,
            let y = (object["y"] as? NSNumber)?.doubleValue
        else {
            throw ToolError.invalidArguments("mouse_click requires numeric x and y")
        }
        let isRight = (object["button"] as? String)?.lowercased() == "right"
        guard await context.ask("Click \(isRight ? "right" : "left") mouse button at (\(Int(x)), \(Int(y)))") else {
            throw ToolError.confirmationDenied("User denied mouse click")
        }
        try ComputerInputSupport.requireAccessibility()
        let point = CGPoint(x: x, y: y)
        let button: CGMouseButton = isRight ? .right : .left
        let down: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)?.post(
            tap: .cghidEventTap
        )
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)?.post(
            tap: .cghidEventTap
        )
        return "Clicked at (\(Int(x)), \(Int(y)))"
    }
}

struct TypeTextTool: AgentTool {
    let definition = ToolDefinition(
        name: "type_text",
        description: "Type Unicode text into the focused application after user approval.",
        parameters: .object(properties: ["text": .string], required: ["text"], additionalProperties: nil)
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try ComputerInputSupport.object(arguments)
        guard let text = object["text"] as? String else {
            throw ToolError.invalidArguments("type_text requires text: string")
        }
        guard await context.ask("Type text into the focused application:\n\(text.prefix(300))") else {
            throw ToolError.confirmationDenied("User denied keyboard input")
        }
        try ComputerInputSupport.requireAccessibility()
        let characters = Array(text.utf16)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            throw ToolError.executionFailed("Failed to create keyboard event")
        }
        event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        event.post(tap: .cghidEventTap)
        return "Typed \(text.count) characters"
    }
}

struct PressKeyTool: AgentTool {
    let definition = ToolDefinition(
        name: "press_key",
        description: "Press a named keyboard key: return, tab, space, delete, escape, or an arrow key.",
        parameters: .object(properties: ["key": .string], required: ["key"], additionalProperties: nil)
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        let object = try ComputerInputSupport.object(arguments)
        guard let key = object["key"] as? String, let code = ComputerInputSupport.keyCode(key) else {
            throw ToolError.invalidArguments("unsupported key")
        }
        guard await context.ask("Press keyboard key: \(key)") else {
            throw ToolError.confirmationDenied("User denied keyboard input")
        }
        try ComputerInputSupport.requireAccessibility()
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        return "Pressed \(key)"
    }
}
