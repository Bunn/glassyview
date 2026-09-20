import Testing
@testable import GlassyDesk

struct SessionFoldFocusStateTests {
    @Test(arguments: [true, false])
    func reconnectingWhileFoldedPreservesOriginalEditorFocus(originalFocus: Bool) {
        var state = SessionFoldFocusState()
        #expect(state.update(folded(active: true), inputFocused: originalFocus)
                == .init(flatFocus: false, foldedFocus: false))
        #expect(state.update(folded(active: false), inputFocused: false)
                == .init(flatFocus: nil, foldedFocus: false))
        #expect(state.update(folded(active: true), inputFocused: false)
                == .init(flatFocus: false, foldedFocus: false))
        #expect(state.update(flat(visible: true), inputFocused: false)
                == .init(flatFocus: originalFocus, foldedFocus: false))
    }

    @Test
    func unfoldingWhileDisconnectedWaitsForRequestedEditorToReturn() {
        var state = SessionFoldFocusState()
        _ = state.update(folded(active: true), inputFocused: true)
        _ = state.update(folded(active: false), inputFocused: false)

        #expect(state.update(flat(visible: false), inputFocused: false)
                == .init(flatFocus: nil, foldedFocus: nil))
        #expect(state.update(flat(visible: true), inputFocused: false)
                == .init(flatFocus: true, foldedFocus: nil))
        // Restoration is consumed, so future layouts cannot steal focus back.
        #expect(state.update(flat(visible: true), inputFocused: false)
                == .init(flatFocus: nil, foldedFocus: nil))
    }

    @Test
    func cancelingFlatInputDoesNotRestoreAnOldFocusRequestLater() {
        var state = SessionFoldFocusState()
        _ = state.update(folded(active: true), inputFocused: true)
        let closedInput = SessionFoldFocusState.Presentation(isSeparated: false,
                                                             isControllerActive: false,
                                                             isInputBarRequested: false,
                                                             isInputBarVisible: false)
        #expect(state.update(closedInput, inputFocused: false)
                == .init(flatFocus: nil, foldedFocus: false))
        #expect(state.update(flat(visible: true), inputFocused: false)
                == .init(flatFocus: nil, foldedFocus: nil))
    }

    @Test(arguments: [true, false])
    func repeatedFoldedUpdatesPreserveManualKeyboardChoice(manualFocus: Bool) {
        var state = SessionFoldFocusState()
        _ = state.update(folded(active: true), inputFocused: true)
        var foldedKeyboardFocused = manualFocus
        for _ in 0..<3 {
            let update = state.update(folded(active: true), inputFocused: false)
            if let focus = update.foldedFocus { foldedKeyboardFocused = focus }
            #expect(update == .init(flatFocus: nil, foldedFocus: nil))
            #expect(foldedKeyboardFocused == manualFocus)
        }
    }

    @Test
    func enteringAndRefoldingStartWithKeyboardHidden() {
        var state = SessionFoldFocusState()
        #expect(state.update(folded(active: true), inputFocused: true)
                == .init(flatFocus: false, foldedFocus: false))
        // The user may open the folded keyboard. Leaving must close it while
        // restoring the saved flat editor; folding again starts hidden anew.
        #expect(state.update(flat(visible: true), inputFocused: false)
                == .init(flatFocus: true, foldedFocus: false))
        #expect(state.update(folded(active: true), inputFocused: true)
                == .init(flatFocus: false, foldedFocus: false))
    }

    private func folded(active: Bool) -> SessionFoldFocusState.Presentation {
        .init(isSeparated: true, isControllerActive: active,
              isInputBarRequested: true, isInputBarVisible: false)
    }

    private func flat(visible: Bool) -> SessionFoldFocusState.Presentation {
        .init(isSeparated: false, isControllerActive: false,
              isInputBarRequested: true, isInputBarVisible: visible)
    }
}
