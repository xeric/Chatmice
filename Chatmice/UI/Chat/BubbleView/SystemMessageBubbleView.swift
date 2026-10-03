import SwiftUI

struct SystemMessageBubbleView: View {
    let message: String
    let color: String?
    let inputBuffer: ChatInputBuffer
    @Binding var editSystemMessage: Bool
    @Binding var searchText: String
    
    var body: some View {
        ChatBubbleView(
            content: ChatBubbleContent(
                message: message,
                own: true,
                waitingForResponse: false,
                errorMessage: nil,
                systemMessage: true,
                isStreaming: false,
                isLatestMessage: false,
                reasoningDuration: nil,
                isActiveReasoning: false
            ),
            color: color,
            onEdit: {
                editSystemMessage = true
                inputBuffer.text = message
            },
            searchText: $searchText
        )
    }
}
