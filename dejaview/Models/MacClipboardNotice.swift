import Foundation
import UIKit
import UniformTypeIdentifiers

/// A brief confirmation of what happened with the Mac's clipboard. It keeps only
/// a short preview, and nothing here is logged or saved.
struct MacClipboardNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case copied(preview: String)
        case filesCopied
        case problem(String)
    }

    let id = UUID()
    let kind: Kind

    /// Nil if the Mac said it sent text but sent none.
    init?(copy: GlassyStreamClipboardCopy) {
        switch copy.outcome {
        case .text:
            guard let text = copy.text else { return nil }
            kind = .copied(preview: Self.preview(of: text))
        case .files:
            kind = .filesCopied
        case .empty:
            kind = .problem(String(localized: "Your Mac's clipboard is empty."))
        case .tooLarge:
            kind = .problem(String(localized: "That's too much text to copy at once. Copy up to 1 MB."))
        case .concealed:
            kind = .problem(String(localized: "This item is marked private on your Mac, so it stayed there."))
        case .notAllowed:
            kind = .problem(String(localized: "Copying is turned off on this Mac, or another device controls it."))
        case .blockedByMac:
            kind = .problem(String(localized: "Your Mac is blocking this. In Privacy & Security on the Mac, set Glassy Desk to Allow under Paste from Other Apps."))
        case .unsupported:
            kind = .problem(String(localized: "Only text can be copied from your Mac for now."))
        }
    }

    /// The first line with text in it, short enough for one line of the toast.
    static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return String((line ?? "").prefix(80))
    }

    /// A lone web address, which apps should also be able to paste as a link.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    static func pasteboardItem(for text: String) -> [String: Any] {
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text]
        if let link = link(in: text) {
            item[UTType.url.identifier] = link
        }
        return item
    }

    /// Stays on this device. Universal Clipboard would hand the text straight
    /// back to a Mac on the same Apple Account, which would then send it again.
    static func writeToPasteboard(_ text: String) {
        UIPasteboard.general.setItems([pasteboardItem(for: text)], options: [.localOnly: true])
    }
}
