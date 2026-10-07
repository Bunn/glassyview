/// Keeps the flat editor's focus intent independent of temporary connection loss
/// while a folded controller is presented. The draft itself stays in SessionView.
struct SessionFoldFocusState {
    struct Presentation: Equatable {
        var isSeparated: Bool
        var isControllerActive: Bool
        var isInputBarRequested: Bool
        var isInputBarVisible: Bool
    }

    struct Update: Equatable {
        var flatFocus: Bool?
        var foldedFocus: Bool?
    }

    private var wasControllerActive = false
    private var savedFlatFocus: Bool?

    mutating func update(_ presentation: Presentation, inputFocused: Bool) -> Update {
        var result = Update()
        if presentation.isControllerActive != wasControllerActive {
            wasControllerActive = presentation.isControllerActive
            // Entering, reconnecting, or leaving the folded controller dismisses
            // its keyboard. Only an explicit keyboard-button tap opens it.
            result.foldedFocus = false
            if presentation.isControllerActive {
                // Reconnecting can recreate the controller without ending the
                // fold. Capture the original editor intent only once.
                if savedFlatFocus == nil { savedFlatFocus = inputFocused }
                result.flatFocus = false
            }
        }

        if !presentation.isSeparated, let savedFlatFocus {
            if presentation.isInputBarVisible {
                result.flatFocus = savedFlatFocus
                self.savedFlatFocus = nil
            } else if !presentation.isInputBarRequested {
                self.savedFlatFocus = nil
            }
            // Unfolding while disconnected cannot restore an absent field.
            // Keep the snapshot until that requested field becomes visible.
        }

        return result
    }
}
