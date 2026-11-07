import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GlassyDesk

@Suite("Mac clipboard")
struct MacClipboardTests {
    @Test func decodesTextAndOutcomes() throws {
        let copy = try GlassyStreamWire.decodeClipboardCopy(Data([0, 1, 0, 0]) + Data("héllo\n".utf8))
        #expect(copy == .init(outcome: .text, isAutomatic: true, text: "héllo\n"))
        #expect(try GlassyStreamWire.decodeClipboardCopy(Data([3, 0, 0, 0]))
            == .init(outcome: .tooLarge, isAutomatic: false))
        #expect(GlassyStreamWire.encodeClipboardCopyRequest(.follow) == Data([1, 0, 0, 0]))
    }

    private static let malformedCopies: [Data] = {
        let oversized = Data([0, 0, 0, 0])
            + Data(repeating: 0x61, count: GlassyStreamWire.maximumClipboardTextLength + 1)
        let invalid: [[UInt8]] = [
            [], [0, 0, 0], [8, 0, 0, 0], [2, 0, 0, 0], [5, 0, 0, 0], [0, 2, 0, 0], [0, 0, 1, 0],
            [0, 0, 0, 0], [0, 0, 0, 0, 0xFF], [3, 0, 0, 0, 0x61]
        ]
        return invalid.map { Data($0) } + [oversized]
    }()

    @Test(arguments: malformedCopies)
    func rejectsMalformedCopies(payload: Data) {
        #expect(throws: (any Error).self) { try GlassyStreamWire.decodeClipboardCopy(payload) }
    }

    @Test func previewShowsFirstLineWithText() {
        #expect(MacClipboardNotice.preview(of: "\n  \n  let x = 1  \nlet y = 2") == "let x = 1")
        #expect(MacClipboardNotice.preview(of: String(repeating: "a", count: 200)).count == 80)
    }

    @Test func loneWebAddressAlsoPastesAsALink() {
        let item = MacClipboardNotice.pasteboardItem(for: " https://example.com/a?b=1\n")
        #expect(item[UTType.utf8PlainText.identifier] as? String == " https://example.com/a?b=1\n")
        #expect((item[UTType.url.identifier] as? URL)?.absoluteString == "https://example.com/a?b=1")

        for text in ["see https://example.com", "file:///etc/hosts", "example", "https://"] {
            #expect(MacClipboardNotice.pasteboardItem(for: text)[UTType.url.identifier] == nil)
        }
    }

    @Test @MainActor func textReachesThePasteboardOnlyWhenWanted() {
        let name = "mac-clipboard-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var written: [String] = []
        let controller = GlassyStreamSessionController()
        let session = GlassyStreamRemoteSession(controller: controller, defaults: defaults,
                                                writeMacClipboard: { written.append($0) })
        #expect(session.followsMacClipboard)

        controller.onClipboardCopy?(.init(outcome: .text, isAutomatic: true, text: "one"))
        #expect(written == ["one"])
        #expect(session.macClipboardNotice?.kind == .copied(preview: "one"))

        session.setFollowsMacClipboard(false)
        #expect(defaults.bool(forKey: "clipboard.followsMac") == false)
        controller.onClipboardCopy?(.init(outcome: .text, isAutomatic: true, text: "late"))
        #expect(written == ["one"])

        session.setFollowsMacClipboard(true)
        controller.onClipboardCopy?(.init(outcome: .tooLarge, isAutomatic: true))
        #expect(written == ["one"])
        if case .problem = session.macClipboardNotice?.kind {} else { Issue.record("Expected a problem notice") }
        session.clearMacClipboardNotice()
        #expect(session.macClipboardNotice == nil)
    }
}
