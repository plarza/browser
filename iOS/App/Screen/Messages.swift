import Observation
import SwiftUI

/// Short messages ("No search engine set. Add one in Settings.") that drop
/// in as a glass capsule along the top and go by themselves.
@MainActor @Observable
final class Messages {
    struct Message: Equatable {
        let id = UUID()
        let text: String
    }

    private(set) var showing: Message?

    func say(_ text: String) {
        let message = Message(text: text)
        showing = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if showing == message { showing = nil }
        }
    }
}

struct MessageCapsule: View {
    let messages: Messages

    var body: some View {
        ZStack {
            if let message = messages.showing {
                Text(message.text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .id(message.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Move.animation(), value: messages.showing)
    }
}
