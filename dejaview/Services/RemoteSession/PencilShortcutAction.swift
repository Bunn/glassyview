import CoreGraphics
import Foundation
import RoyalVNCKit

/// What an Apple Pencil double-tap or squeeze does on the remote Mac. The
/// system setting still wins: when Settings › Apple Pencil says to ignore the
/// gesture, Glassy Desk does nothing.
enum PencilShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case secondaryClick
    case undo
    case escape
    case nothing

    static let preferenceKey = "pencil.shortcutAction"
    static let defaultAction = PencilShortcutAction.secondaryClick

    static func current(in defaults: UserDefaults = .standard) -> PencilShortcutAction {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultAction
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .secondaryClick: String(localized: "Secondary Click")
        case .undo: String(localized: "Undo (⌘Z)")
        case .escape: String(localized: "Escape")
        case .nothing: String(localized: "Nothing")
        }
    }

    /// What the action sends, independent of the transport.
    enum Command: Equatable, Sendable {
        case secondaryClick
        case commandShortcut(character: String)
        case escapeKey
        case none
    }

    var command: Command {
        switch self {
        case .secondaryClick: .secondaryClick
        case .undo: .commandShortcut(character: "z")
        case .escape: .escapeKey
        case .nothing: .none
        }
    }

    /// `point` is where the Pencil hovers, in framebuffer coordinates, when known.
    @MainActor
    func perform(on session: any RemoteSessionInputControlling, at point: CGPoint?) {
        switch command {
        case .secondaryClick:
            if let point {
                session.rightClick(at: point)
            } else {
                session.rightClickAtCursor()
            }
        case let .commandShortcut(character):
            session.sendText(character, modifiers: [RemoteModifierKey.command.keyCode])
        case .escapeKey:
            session.sendKey(.escape)
        case .none:
            break
        }
    }
}
