import SwiftUI

/// Prefer the input pane, retaining reachable actions if the native keyboard
/// covers that pane completely. Placement follows the current layout pass.
struct SessionFoldedToolbarPlacement<Content: View>: View {
    @Environment(\.foldedToolbarUsesControlsPane) private var usesControlsPane
    let isControlsPane: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        if usesControlsPane == isControlsPane {
            content()
        }
    }
}

/// Essential actions keep fixed touch targets in either folded pane orientation.
/// Additional session controls live in Options, rather than a scrolling toolbar.
struct SessionFoldedToolbar<Options: View>: View {
    let isKeyboardVisible: Bool
    let toggleKeyboard: () -> Void
    let close: () -> Void
    @ViewBuilder var options: () -> Options

    var body: some View {
        HStack(spacing: 2) {
            options()
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("session.folded-options")
            Button(isKeyboardVisible ? "Hide Software Keyboard" : "Show Software Keyboard",
                   systemImage: isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                   action: toggleKeyboard)
                .accessibilityIdentifier("session.folded-keyboard.toggle")
            Button("Close Session", systemImage: "xmark", action: close)
                .accessibilityIdentifier("session.folded-close")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FoldedSessionButtonStyle())
        .font(.body.weight(.medium))
        .foregroundStyle(.white)
        .padding(2)
        .liquidGlass(in: Capsule())
        .fixedSize()
    }
}

private struct FoldedSessionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
