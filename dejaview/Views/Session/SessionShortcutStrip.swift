import RoyalVNCKit
import SwiftUI

struct SessionShortcutStrip<Session: RemoteSessionInputControlling>: View {
    let session: Session
    @Binding var heldModifierKeys: Set<RemoteModifierKey>
    let onSend: () -> Void

    private let primaryActions: [SessionShortcutAction] = [
        .key(id: "escape", title: "Esc", keyCode: .escape),
        .key(id: "tab", title: "Tab", keyCode: .tab),
        .key(id: "backspace", title: "Backspace", systemImage: "delete.left", keyCode: .delete),
        .key(id: "left", title: "Left", systemImage: "arrow.left", keyCode: .leftArrow),
        .key(id: "up", title: "Up", systemImage: "arrow.up", keyCode: .upArrow),
        .key(id: "down", title: "Down", systemImage: "arrow.down", keyCode: .downArrow),
        .key(id: "right", title: "Right", systemImage: "arrow.right", keyCode: .rightArrow),
        .key(id: "cmd-tab", title: "Cmd+Tab", keyCode: .tab, modifiers: [.command]),
        .text(id: "cmd-q", title: "Cmd+Q", text: "q", modifiers: [.command])
    ]

    private let functionActions: [SessionShortcutAction] = [
        .key(id: "f1", title: "F1", keyCode: .f1),
        .key(id: "f2", title: "F2", keyCode: .f2),
        .key(id: "f3", title: "F3", keyCode: .f3),
        .key(id: "f4", title: "F4", keyCode: .f4),
        .key(id: "f5", title: "F5", keyCode: .f5),
        .key(id: "f6", title: "F6", keyCode: .f6),
        .key(id: "f7", title: "F7", keyCode: .f7),
        .key(id: "f8", title: "F8", keyCode: .f8),
        .key(id: "f9", title: "F9", keyCode: .f9),
        .key(id: "f10", title: "F10", keyCode: .f10),
        .key(id: "f11", title: "F11", keyCode: .f11),
        .key(id: "f12", title: "F12", keyCode: .f12)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(RemoteModifierKey.allCases) { modifier in
                    modifierButton(for: modifier)
                }

                Divider()
                    .frame(height: 22)
                    .overlay(.white.opacity(0.28))
                    .padding(.horizontal, 2)

                ForEach(primaryActions) { action in
                    shortcutButton(for: action)
                }

                functionKeysMenu
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .liquidGlass(in: Capsule())
    }

    private func modifierButton(for modifier: RemoteModifierKey) -> some View {
        let isActive = heldModifierKeys.contains(modifier)

        return Button {
            setModifier(modifier, isActive: !isActive)
        } label: {
            Text(modifier.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, height: 44)
                .background {
                    if isActive {
                        Capsule()
                            .fill(.white.opacity(0.20))
                    }
                }
                .overlay {
                    if isActive {
                        Capsule()
                            .stroke(.white.opacity(0.32), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(modifier.title)
        .accessibilityValue(
            isActive ? String(localized: "Held") : String(localized: "Not held")
        )
    }

    @ViewBuilder
    private func shortcutButton(for action: SessionShortcutAction) -> some View {
        Button {
            send(action)
        } label: {
            shortcutLabel(for: action)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(action.accessibilityTitle)
    }

    @ViewBuilder
    private func shortcutLabel(for action: SessionShortcutAction) -> some View {
        if let systemImage = action.systemImage {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Capsule())
        } else {
            Text(action.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: max(44, action.minimumWidth), minHeight: 44)
                .contentShape(Capsule())
        }
    }

    private var functionKeysMenu: some View {
        Menu {
            ForEach(functionActions) { action in
                Button(action.title) {
                    send(action)
                }
            }
        } label: {
            Text("Fn")
                .font(.caption.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Function keys")
    }

    private func send(_ action: SessionShortcutAction) {
        action.send(through: session)
        onSend()
    }

    private func setModifier(_ modifier: RemoteModifierKey, isActive: Bool) {
        var updatedModifierKeys = heldModifierKeys

        if isActive {
            updatedModifierKeys.insert(modifier)
        } else {
            updatedModifierKeys.remove(modifier)
        }

        heldModifierKeys = updatedModifierKeys
        session.setModifier(modifier, isPressed: isActive)
    }
}

private struct SessionShortcutAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String?
    let action: Action

    var accessibilityTitle: String {
        title.replacingOccurrences(of: "+", with: " ")
    }

    var minimumWidth: CGFloat {
        title.count > 4 ? 68 : 34
    }

    static func key(id: String,
                    title: LocalizedStringResource,
                    systemImage: String? = nil,
                    keyCode: VNCKeyCode,
                    modifiers: [VNCKeyCode] = []) -> Self {
        Self(id: id,
             title: String(localized: title),
             systemImage: systemImage,
             action: .key(keyCode, modifiers: modifiers))
    }

    static func text(id: String,
                     title: LocalizedStringResource,
                     systemImage: String? = nil,
                     text: String,
                     modifiers: [VNCKeyCode] = []) -> Self {
        Self(id: id,
             title: String(localized: title),
             systemImage: systemImage,
             action: .text(text, modifiers: modifiers))
    }

    func send(through session: some RemoteSessionInputControlling) {
        switch action {
        case .key(let keyCode, let modifiers):
            session.sendKey(keyCode, modifiers: modifiers)
        case .text(let text, let modifiers):
            session.sendText(text, modifiers: modifiers)
        }
    }

    enum Action {
        case key(VNCKeyCode, modifiers: [VNCKeyCode])
        case text(String, modifiers: [VNCKeyCode])
    }
}
