//
//  BuiltInModelMetadata.swift
//  Chatmice
//

import Foundation

enum BuiltInModelMetadata {
    static let values: [String: ModelMetadata] = {
        var values: [String: ModelMetadata] = [:]
        addOpenAI(to: &values)
        addAnthropic(to: &values)
        addGoogleAndXAI(to: &values)
        addAlibaba(to: &values)
        addZAIAndDeepSeek(to: &values)
        return values
    }()

    static func add(
        provider: String,
        modelIDs: [String],
        context: Int,
        output: Int?,
        input: [String],
        reasoning: Bool = true,
        tools: Bool = true,
        structured: Bool = true,
        temperature: Bool = true,
        to values: inout [String: ModelMetadata]
    ) {
        for modelID in modelIDs {
            let metadata = ModelMetadata(
                id: modelID,
                canonicalModelID: "\(provider)/\(modelID)",
                limit: .init(context: context, output: output),
                modalities: .init(input: input, output: ["text"]),
                attachment: input.count > 1,
                reasoning: reasoning,
                toolCall: tools,
                structuredOutput: structured,
                temperature: temperature
            )
            values[modelID] = metadata
        }
    }
}

extension BuiltInModelMetadata {
    private static func addOpenAI(to values: inout [String: ModelMetadata]) {
        add(
            provider: "openai",
            modelIDs: ["gpt-5", "gpt-5-mini", "gpt-5-nano"],
            context: 400_000,
            output: 128_000,
            input: ["text", "image"],
            temperature: false,
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.1", "gpt-5.2", "gpt-5.4-mini", "gpt-5.4-nano"],
            context: 400_000,
            output: 128_000,
            input: ["text", "image"],
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5-pro"],
            context: 400_000,
            output: 272_000,
            input: ["text", "image"],
            temperature: false,
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.2-pro"],
            context: 400_000,
            output: 128_000,
            input: ["text", "image"],
            structured: false,
            temperature: false,
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.3-codex"],
            context: 400_000,
            output: 128_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.3-codex-spark"],
            context: 128_000,
            output: 32_000,
            input: ["text", "image", "pdf"],
            temperature: false,
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.4"],
            context: 1_050_000,
            output: 128_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: ["gpt-5.4-pro"],
            context: 1_050_000,
            output: 128_000,
            input: ["text", "image"],
            structured: false,
            temperature: false,
            to: &values
        )
        add(
            provider: "openai",
            modelIDs: [
                "gpt-5.5", "gpt-5.5-pro", "gpt-5.6", "gpt-5.6-luna", "gpt-5.6-sol",
                "gpt-5.6-terra", "gpt-6", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol", "gpt-6.1",
                "gpt-6.1-sol"
            ],
            context: 1_050_000,
            output: 128_000,
            input: ["text", "image", "pdf"],
            temperature: false,
            to: &values
        )
    }
}

extension BuiltInModelMetadata {
    private static func addAnthropic(to values: inout [String: ModelMetadata]) {
        add(
            provider: "anthropic",
            modelIDs: ["claude-3-7-sonnet", "claude-3-7-sonnet-20250219"],
            context: 200_000,
            output: 64_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "anthropic",
            modelIDs: [
                "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-opus-4-5",
                "claude-opus-4-5-20251101", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929"
            ],
            context: 200_000,
            output: 64_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "anthropic",
            modelIDs: ["claude-opus-4-6", "claude-sonnet-4-6"],
            context: 1_000_000,
            output: 128_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "anthropic",
            modelIDs: [
                "claude-fable-5", "claude-fable-5-1", "claude-haiku-5-5", "claude-opus-4-7",
                "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5",
                "claude-sonnet-5-5"
            ],
            context: 1_000_000,
            output: 128_000,
            input: ["text", "image", "pdf"],
            temperature: false,
            to: &values
        )
    }
}

extension BuiltInModelMetadata {
    private static func addGoogleAndXAI(to values: inout [String: ModelMetadata]) {
        add(
            provider: "google",
            modelIDs: [
                "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview",
                "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools", "gemini-3.5-flash",
                "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"
            ],
            context: 1_048_576,
            output: 65_536,
            input: ["text", "image", "video", "audio", "pdf"],
            to: &values
        )
        add(
            provider: "google",
            modelIDs: ["gemini-3.1-flash-image"],
            context: 131_072,
            output: 32_768,
            input: ["text", "image", "video", "pdf"],
            tools: false,
            structured: false,
            to: &values
        )
        add(
            provider: "google",
            modelIDs: ["gemini-4-argon"],
            context: 1_048_576,
            output: 32_768,
            input: ["text", "image", "video", "audio", "pdf"],
            to: &values
        )
        add(
            provider: "xai",
            modelIDs: ["grok-4.20-0309-reasoning", "grok-4.3"],
            context: 1_000_000,
            output: 30_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "xai",
            modelIDs: ["grok-4.20-0309-non-reasoning"],
            context: 1_000_000,
            output: 30_000,
            input: ["text", "image", "pdf"],
            reasoning: false,
            to: &values
        )
        add(
            provider: "xai",
            modelIDs: ["grok-4.20-multi-agent-0309"],
            context: 1_000_000,
            output: 30_000,
            input: ["text", "image", "pdf"],
            tools: false,
            to: &values
        )
        add(
            provider: "xai",
            modelIDs: ["grok-4.5", "grok-4.6", "grok-4.7"],
            context: 500_000,
            output: 500_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
        add(
            provider: "xai",
            modelIDs: ["grok-build-0.1"],
            context: 256_000,
            output: 256_000,
            input: ["text", "image", "pdf"],
            to: &values
        )
    }
}

extension BuiltInModelMetadata {
    private static func addAlibaba(to values: inout [String: ModelMetadata]) {
        add(
            provider: "alibaba",
            modelIDs: ["qwen3-max", "qwen3-coder-30b-a3b-instruct", "qwen3-coder-480b-a35b-instruct"],
            context: 262_144,
            output: 65_536,
            input: ["text"],
            reasoning: false,
            structured: false,
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3-coder-plus"],
            context: 1_048_576,
            output: 65_536,
            input: ["text"],
            reasoning: false,
            structured: false,
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3-vl-plus"],
            context: 262_144,
            output: 32_768,
            input: ["text", "image"],
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.5-flash", "qwen3.5-plus", "qwen3.6-flash", "qwen3.6-plus"],
            context: 1_000_000,
            output: 65_536,
            input: ["text", "image", "video"],
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.6-max-preview"],
            context: 262_144,
            output: 65_536,
            input: ["text"],
            structured: false,
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.7-flash", "qwen3.7-plus", "qwen3.8-flash"],
            context: 1_000_000,
            output: 131_072,
            input: ["text", "image", "video"],
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.7-max"],
            context: 1_000_000,
            output: 131_072,
            input: ["text"],
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.8-max"],
            context: 1_000_000,
            output: 131_072,
            input: ["text", "image", "video", "pdf"],
            to: &values
        )
        add(
            provider: "alibaba",
            modelIDs: ["qwen3.8-omni-flash"],
            context: 1_000_000,
            output: 131_072,
            input: ["text", "image", "audio", "video"],
            to: &values
        )
    }
}

extension BuiltInModelMetadata {
    private static func addZAIAndDeepSeek(to values: inout [String: ModelMetadata]) {
        add(
            provider: "zai",
            modelIDs: ["glm-5"],
            context: 204_800,
            output: 131_072,
            input: ["text"],
            structured: false,
            to: &values
        )
        add(
            provider: "zai",
            modelIDs: ["glm-5-turbo", "glm-5.1"],
            context: 200_000,
            output: 131_072,
            input: ["text"],
            to: &values
        )
        add(
            provider: "zai",
            modelIDs: ["glm-5.2", "glm-5.3"],
            context: 1_000_000,
            output: 131_072,
            input: ["text"],
            to: &values
        )
        add(
            provider: "zai",
            modelIDs: ["glm-5.3-flash", "glm-5.3-flashx"],
            context: 1_000_000,
            output: 131_072,
            input: ["text", "image", "video", "pdf"],
            to: &values
        )
        add(
            provider: "deepseek",
            modelIDs: ["deepseek-chat", "deepseek-reasoner"],
            context: 1_000_000,
            output: nil,
            input: ["text"],
            to: &values
        )
        add(
            provider: "deepseek",
            modelIDs: ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
            context: 1_048_576,
            output: 393_216,
            input: ["text", "image"],
            to: &values
        )
        add(
            provider: "deepseek",
            modelIDs: ["deepseek-v4-pro"],
            context: 1_048_576,
            output: 393_216,
            input: ["text"],
            to: &values
        )
    }
}
