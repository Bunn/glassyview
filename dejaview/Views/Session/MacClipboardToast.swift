import SwiftUI
import UIKit

/// Confirms a copy from the Mac without taking over the screen. It passes touches
/// through to the remote desktop unless it has a button.
struct MacClipboardToast: View {
    let notice: MacClipboardNotice?
    let canGetFiles: Bool
    let getFiles: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice {
                content(for: notice)
                    .id(notice.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        AccessibilityNotification.Announcement(announcement(for: notice)).post()
                        try? await Task.sleep(for: duration(of: notice))
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: notice?.id)
        .sensoryFeedback(.impact(weight: .light), trigger: notice?.id) { _, id in id != nil }
    }

    @ViewBuilder
    private func content(for notice: MacClipboardNotice) -> some View {
        switch notice.kind {
        case let .copied(preview):
            pill(systemImage: "checkmark.circle.fill", tint: .green,
                 title: copiedTitle, detail: preview)
                .allowsHitTesting(false)
        case .filesCopied:
            pill(systemImage: "doc.on.doc.fill", tint: .white,
                 title: String(localized: "Files copied on your Mac"), detail: nil) {
                if canGetFiles {
                    Button("Get Files") {
                        getFiles()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            .allowsHitTesting(canGetFiles)
        case let .problem(message):
            pill(systemImage: "info.circle.fill", tint: .white, title: message, detail: nil)
                .allowsHitTesting(false)
        }
    }

    private func pill(systemImage: String,
                      tint: Color,
                      title: String,
                      detail: String?,
                      @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            accessory()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), isInteractive: false)
        .accessibilityElement(children: .contain)
    }

    private var copiedTitle: String {
        String(localized: "Copied to \(UIDevice.current.localizedModel)",
               comment: "Confirms text copied on the Mac is on this device. The argument is iPhone or iPad.")
    }

    private func announcement(for notice: MacClipboardNotice) -> String {
        switch notice.kind {
        case .copied: copiedTitle
        case .filesCopied: String(localized: "Files copied on your Mac")
        case let .problem(message): message
        }
    }

    private func duration(of notice: MacClipboardNotice) -> Duration {
        switch notice.kind {
        case .copied: .seconds(2)
        case .filesCopied: .seconds(6)
        case .problem: .seconds(5)
        }
    }
}

#Preview("Copied") {
    ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        VStack(spacing: 16) {
            MacClipboardToast(notice: MacClipboardNotice(copy: .init(outcome: .text, isAutomatic: true,
                                                                     text: "https://example.com/builds/2841\nsecond line")),
                              canGetFiles: false, getFiles: {}, dismiss: {})
            MacClipboardToast(notice: MacClipboardNotice(copy: .init(outcome: .files, isAutomatic: true)),
                              canGetFiles: true, getFiles: {}, dismiss: {})
            MacClipboardToast(notice: MacClipboardNotice(copy: .init(outcome: .blockedByMac, isAutomatic: false)),
                              canGetFiles: false, getFiles: {}, dismiss: {})
        }
    }
}
