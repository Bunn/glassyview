import Foundation

/// Controls how the session's on-screen keyboard reaches the remote machine.
enum KeyboardInputPreference {
    /// When on, each keystroke is sent immediately instead of being typed into
    /// a local field and sent on Return.
    nonisolated static let sendsKeystrokesInstantlyKey = "keyboard.sendsKeystrokesInstantly"
    nonisolated static let defaultSendsKeystrokesInstantly = false
}
