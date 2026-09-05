import Testing
import UIKit
@testable import GlassyDesk

@MainActor
struct RemoteClipboardInputTests {
    @Test
    func checkingPasteAvailabilityNeverReadsClipboardContent() {
        let view = PasteInputFixture()
        var reads = 0
        view.readPasteboardText = { reads += 1; return "private text" }
        view.hasPasteboardText = { true }
        for _ in 0..<20 {
            #expect(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
            #expect(view.keyCommands?.last?.action == #selector(view.paste(_:)))
        }
        #expect(reads == 0)
        #expect(view.pastedTexts.isEmpty)
    }

    @Test
    func eachExplicitPasteReadsAndSendsExactlyOnce() {
        let view = PasteInputFixture()
        var reads = 0
        let text = "  One\r\nTwo 👩🏽‍💻\t"
        view.readPasteboardText = { reads += 1; return text }
        view.paste(nil)
        view.paste(nil)
        #expect(reads == 2)
        #expect(view.pastedTexts == [text, text])
    }

    @Test
    func deniedReadIsNotRetriedAndUnavailableSessionDoesNotRead() async {
        let view = PasteInputFixture()
        var reads = 0
        view.readPasteboardText = { reads += 1; return nil }
        view.paste(nil)
        await Task.yield()
        #expect(reads == 1)
        #expect(view.pastedTexts.isEmpty)
        view.isAvailable = false
        view.paste(nil)
        #expect(reads == 1)
        #expect(!view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
    }

    @Test
    func onlyPlainCommandVPastesFromIOS() {
        let view = PasteInputFixture()
        #expect(view.routesThroughSystemPaste(keyCode: .keyboardV, modifiers: .command))
        #expect(view.routesThroughSystemPaste(keyCode: .keyboardV, modifiers: [.command, .alphaShift]))
        #expect(!view.routesThroughSystemPaste(keyCode: .keyboardV, modifiers: [.command, .shift]))
        #expect(!view.routesThroughSystemPaste(keyCode: .keyboardV, modifiers: .control))
        #expect(!view.routesThroughSystemPaste(keyCode: .keyboardC, modifiers: .command))
        view.isAvailable = false
        #expect(!view.routesThroughSystemPaste(keyCode: .keyboardV, modifiers: .command))
    }

    @Test
    func externalKeyboardPasteDoesNotTurnNewlinesIntoReturnKeys() {
        let view = RemoteSoftwareKeyboardInput.InputView()
        var pasted: [String] = []
        var typed: [String] = []
        var returns = 0
        view.onPasteText = { pasted.append($0) }
        view.onInsertText = { typed.append($0) }
        view.onReturn = { returns += 1 }
        view.readPasteboardText = { "one\ntwo" }
        view.paste(nil)
        #expect(pasted == ["one\ntwo"])
        #expect(typed.isEmpty)
        #expect(returns == 0)
        view.deactivate()
        view.paste(nil)
        #expect(pasted.count == 1)
    }
}

@MainActor
private final class PasteInputFixture: RemoteClipboardInputView {
    var isAvailable = true
    var pastedTexts: [String] = []
    override var acceptsRemotePaste: Bool { isAvailable }
    override func sendPasteText(_ text: String) { pastedTexts.append(text) }
}
