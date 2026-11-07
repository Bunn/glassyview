import AppKit
import Foundation
import Testing
@testable import GlassyHost

private final class FakeClipboard: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (count: Int, types: [String], text: String?, denied: Bool, reads: Int, time: TimeInterval)
        = (1, ["public.utf8-plain-text"], "first", false, 0, 100)
    private var sent: [(HostProtocol.ClipboardCopy, UUID)] = []

    func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
        lock.withLock {
            state.count += 1
            state.text = text
            state.types = types
        }
    }
    func deny() { lock.withLock { state.denied = true } }
    func advance(_ seconds: TimeInterval) { lock.withLock { state.time += seconds } }
    var reads: Int { lock.withLock { state.reads } }
    var received: [HostProtocol.ClipboardCopy] { lock.withLock { sent.map(\.0) } }
    var recipients: [UUID] { lock.withLock { sent.map(\.1) } }

    func makeService(defaults: UserDefaults) -> HostClipboardCopyService {
        HostClipboardCopyService(
            send: { [self] copy, client in lock.withLock { sent.append((copy, client)) } },
            pasteboard: .init(
                changeCount: { [self] in lock.withLock { state.count } },
                types: { [self] in lock.withLock { state.types } },
                readText: { [self] in lock.withLock { state.reads += 1; return state.text } },
                isDenied: { [self] in lock.withLock { state.denied } }
            ),
            defaults: defaults,
            now: { [self] in lock.withLock { state.time } },
            pollInterval: nil
        )
    }
}

private func isolatedDefaults() -> UserDefaults {
    let name = "clipboard-copy-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test("Clipboard copy messages use capability bit 10 and fixed headers")
func clipboardCopyCodec() throws {
    #expect(HostProtocol.Capabilities.clipboardCopy.rawValue == 1 << 10)
    #expect(HostProtocol.advertisedCapabilities.contains(.clipboardCopy))
    #expect(HostProtocol.MessageKind.clipboardCopyRequest.rawValue == 0x27)
    #expect(HostProtocol.MessageKind.clipboardCopy.rawValue == 0x28)

    for request in HostProtocol.ClipboardCopyRequest.allCases {
        #expect(try HostProtocol.decodeClipboardCopyRequest(HostProtocol.encodeClipboardCopyRequest(request)) == request)
    }
    for invalid in [Data(), Data([2, 0, 0, 0]), Data([3, 0, 0, 0]), Data([1, 0, 1, 0]), Data([1, 0, 0])] {
        #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeClipboardCopyRequest(invalid) }
    }
    #expect(HostProtocol.encodeClipboardCopy(.init(outcome: .text, isAutomatic: true, text: "é"))
        == Data([0, 1, 0, 0, 0xC3, 0xA9]))
    #expect(HostProtocol.encodeClipboardCopy(.init(outcome: .tooLarge, isAutomatic: false)) == Data([3, 0, 0, 0]))
}

@Test("Clipboard types decide what happens, with private items winning over text and files")
func clipboardCopyPolicy() {
    let text = "public.utf8-plain-text"
    let file = "public.file-url"
    #expect(HostClipboardCopyPolicy.contents(ofTypes: []) == .empty)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: [text]) == .text)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: [text, file]) == .files)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: ["public.png"]) == .unsupported)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: [text, "org.nspasteboard.ConcealedType"]) == .concealed)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: [file, "org.nspasteboard.TransientType"]) == .concealed)
    #expect(HostClipboardCopyPolicy.contents(ofTypes: [text, HostClipboardCopyPolicy.fromDeviceType.rawValue]) == .fromDevice)
}

@Test("A device receives only what its own input copied")
func clipboardCopyFollowsDeviceInput() {
    let clipboard = FakeClipboard()
    let service = clipboard.makeService(defaults: isolatedDefaults())
    let device = UUID()

    service.handle(.follow, from: device)
    service.checkForChangesAndWait()
    #expect(clipboard.received.isEmpty) // Already on the clipboard before following.

    clipboard.copy("no input yet")
    service.checkForChangesAndWait()
    #expect(clipboard.reads == 0)

    service.noteRemoteInput()
    clipboard.copy("hello")
    service.checkForChangesAndWait()
    service.checkForChangesAndWait() // One copy sends once.
    #expect(clipboard.received == [.init(outcome: .text, isAutomatic: true, text: "hello")])
    #expect(clipboard.recipients == [device])

    clipboard.advance(HostClipboardCopyService.recentInputWindow + 1)
    clipboard.copy("someone at the Mac")
    service.checkForChangesAndWait()
    #expect(clipboard.reads == 1)
    #expect(clipboard.received.count == 1)
}

@Test("Private items, device text and stopped followers are never read automatically")
func clipboardCopySkipsWithoutReading() {
    let clipboard = FakeClipboard()
    let defaults = isolatedDefaults()
    let service = clipboard.makeService(defaults: defaults)
    let device = UUID()
    service.handle(.follow, from: device)
    service.checkForChangesAndWait()
    service.noteRemoteInput()

    clipboard.copy("secret", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
    service.checkForChangesAndWait()
    clipboard.copy("pasted", types: ["public.utf8-plain-text", HostClipboardCopyPolicy.fromDeviceType.rawValue])
    service.checkForChangesAndWait()
    clipboard.copy(nil, types: ["public.png"])
    service.checkForChangesAndWait()

    service.allowsCopy = false
    clipboard.copy("turned off")
    service.checkForChangesAndWait()
    service.allowsCopy = true

    service.handle(.stopFollowing, from: device)
    clipboard.copy("stopped")
    service.checkForChangesAndWait()

    service.handle(.follow, from: device)
    service.clientEnded(device)
    clipboard.copy("gone")
    service.checkForChangesAndWait()

    #expect(clipboard.reads == 0)
    #expect(clipboard.received.isEmpty)
}

@Test("Copied files stay on the Mac, and too much text is explained")
func clipboardCopyFilesAndLimits() {
    let clipboard = FakeClipboard()
    let service = clipboard.makeService(defaults: isolatedDefaults())
    let device = UUID()
    service.handle(.follow, from: device)
    service.checkForChangesAndWait()
    service.noteRemoteInput()

    clipboard.copy("report.pdf", types: ["public.utf8-plain-text", "public.file-url"])
    service.checkForChangesAndWait()
    #expect(clipboard.reads == 0)

    clipboard.copy(String(repeating: "a", count: HostProtocol.maximumClipboardTextLength))
    service.checkForChangesAndWait()
    clipboard.copy(String(repeating: "a", count: HostProtocol.maximumClipboardTextLength + 1))
    service.checkForChangesAndWait()
    clipboard.copy("")
    service.checkForChangesAndWait()

    #expect(clipboard.received.map(\.outcome) == [.text, .tooLarge])
    #expect(clipboard.received[1].text == nil)
}

@Test("A macOS denial is explained once per device and never reads")
func clipboardCopyDenied() {
    let clipboard = FakeClipboard()
    let service = clipboard.makeService(defaults: isolatedDefaults())
    let device = UUID()
    clipboard.deny()
    service.handle(.follow, from: device)
    service.checkForChangesAndWait()
    service.noteRemoteInput()

    clipboard.copy("one")
    service.checkForChangesAndWait()
    clipboard.copy("two")
    service.checkForChangesAndWait()

    #expect(clipboard.reads == 0)
    #expect(clipboard.received == [.init(outcome: .blockedByMac, isAutomatic: true)])
}
