//
//  ErrorMessage.swift
//  Chatmice
//
//  Created by Renat Notfullin on 01.12.2024.
//

import SwiftUI

struct ErrorMessage {
    let type: APIError
    let timestamp: Date
    var retryCount: Int = 0

    var displayTitle: String {
        switch type {
        case .requestFailed(_):
            return "Connection Error"
        case .invalidResponse:
            return "Invalid Response"
        case .decodingFailed(_):
            return "Processing Error"
        case .unauthorized:
            return "Authentication Error"
        case .rateLimited:
            return "Rate Limited"
        case .serverError(_):
            return "Server Error"
        case .unknown(_):
            return "Unknown Error"
        case .noApiService(_):
            return "No API Service selected"
        case .attachmentNotReady(_):
            return "Attachment Error"
        }
    }

    var displayMessage: String {
        switch type {
        case .requestFailed(let error):
            return "Failed to connect: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received invalid response from server"
        case .decodingFailed(let message):
            return "Failed to process response: \(message)"
        case .unauthorized:
            return "Invalid API key or unauthorized access"
        case .rateLimited:
            return "Too many requests. Please wait a moment"
        case .serverError(let message):
            return Self.readableServerError(message)
        case .unknown(let message):
            return message
        case .noApiService(let message):
            return message
        case .attachmentNotReady(let message):
            return message
        }
    }

    private static func readableServerError(_ message: String) -> String {
        let upstreamMessage = extractedUpstreamMessage(from: message) ?? message
        if upstreamMessage.localizedCaseInsensitiveContains("prompt is too long") {
            return "The request exceeded the model's context limit. The conversation or attached media is too large. Reduce attachments, start a new chat, or retry."
        }
        if upstreamMessage.localizedCaseInsensitiveContains("context length")
            || upstreamMessage.localizedCaseInsensitiveContains("maximum context")
        {
            return "The request exceeded the model's context limit. Shorten the conversation or attachments and retry."
        }
        return upstreamMessage
    }

    private static func extractedUpstreamMessage(from raw: String) -> String? {
        guard let jsonStart = raw.firstIndex(of: "{") else { return nil }
        let json = String(raw[jsonStart...])
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let nested = object["error"] as? [String: Any],
            let message = nested["message"] as? String, !message.isEmpty
        {
            return message
        }
        for key in ["errorMessage", "message", "detail", "error_description"] {
            guard let value = object[key] as? String, !value.isEmpty else { continue }
            return extractedUpstreamMessage(from: value) ?? value
        }
        return nil
    }

    var canRetry: Bool {
        switch type {
        case .unauthorized: return false
        default: return retryCount < 3
        }
    }
}

struct ErrorBubbleView: View {
    let error: ErrorMessage
    let onRetry: () -> Void
    let onIgnore: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(error.displayTitle)
                            .font(.headline)
                            .foregroundColor(.white)

                        if error.canRetry {
                            Button(action: onRetry) {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .clipShape(Capsule())
                            .frame(height: 12)
                        }
                    }

                    if !error.displayMessage.isEmpty {
                        Text(error.displayMessage)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.95))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.orange.opacity(0.8))
        .cornerRadius(16)
    }
}

#Preview {
    VStack(spacing: 20) {
        ErrorBubbleView(
            error: ErrorMessage(
                type: .requestFailed(NSError(domain: "network", code: -1009)),
                timestamp: Date()
            ),
            onRetry: {},
            onIgnore: {}
        )

        ErrorBubbleView(
            error: ErrorMessage(
                type: .unauthorized,
                timestamp: Date()
            ),
            onRetry: {},
            onIgnore: {}
        )

        ErrorBubbleView(
            error: ErrorMessage(
                type: .serverError("Internal server error occurred"),
                timestamp: Date()
            ),
            onRetry: {},
            onIgnore: {}
        )
    }
    .padding()
    .background(Color(.windowBackgroundColor))
}
