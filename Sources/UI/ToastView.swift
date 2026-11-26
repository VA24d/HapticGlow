// Toast overlay bound to AppModel.toast (slides in from the top; the model clears it after 2.5 s).
import SwiftUI

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .accessibilityAddTraits(.isStaticText)
    }
}

private struct ToastOverlay: ViewModifier {
    @State private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = model.toast {
                ToastView(text: t)
                    .id(t)
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28), value: model.toast)    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
