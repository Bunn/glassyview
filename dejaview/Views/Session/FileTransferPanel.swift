import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Floating list of the session's file transfers.
struct FileTransferPanel: View {
    @Bindable var center: FileTransferCenter
    @Environment(\.openURL) private var openURL

    private let visibleLimit = 3

    var body: some View {
        if !center.items.isEmpty || center.requestMessage != nil || center.isRequestingFiles {
            VStack(alignment: .leading, spacing: 10) {
                if center.isRequestingFiles {
                    Label("Asking your Mac for the selected files…", systemImage: "arrow.down.circle.dotted")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let message = center.requestMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss", systemImage: "xmark") { center.requestMessage = nil }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                    }
                }
                ForEach(center.items.prefix(visibleLimit)) { item in
                    FileTransferRow(item: item,
                                    cancel: { center.cancel(item) },
                                    dismiss: { center.dismiss(item) },
                                    showInFiles: showInFiles)
                }
                if center.items.count > visibleLimit {
                    HStack {
                        Text("\(center.items.count - visibleLimit) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if center.items.contains(where: { $0.state.isFinished }) {
                            Button("Clear Finished", action: center.dismissFinished)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 420)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("File Transfers")
        }
    }

    private func showInFiles(_ url: URL) {
        // Opens the Files app at the folder that holds received files.
        guard let folder = URL(string: "shareddocuments://" + url.deletingLastPathComponent().path) else { return }
        openURL(folder)
    }
}

private struct FileTransferRow: View {
    let item: FileTransferCenter.Item
    let cancel: () -> Void
    let dismiss: () -> Void
    let showInFiles: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.state.isFinished {
                    ProgressView(value: item.fractionCompleted)
                        .tint(.white)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingControls
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingControls: some View {
        if !item.state.isFinished {
            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 14) {
                if case .completed = item.state, let fileURL = item.fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    Button("Show in Files", systemImage: "folder") { showInFiles(fileURL) }
                        .labelStyle(.iconOnly)
                }
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.medium))
        }
    }

    private var systemImage: String {
        switch item.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        default: item.direction == .outgoing ? "arrow.up.doc" : "arrow.down.doc"
        }
    }

    private var tint: Color {
        switch item.state {
        case .completed: .green
        case .failed(.cancelled, _): .secondary
        case .failed: .orange
        default: .white
        }
    }

    private var detail: String {
        let total = Int64(clamping: item.totalBytes).formatted(.byteCount(style: .file))
        let done = Int64(clamping: item.transferredBytes).formatted(.byteCount(style: .file))
        switch item.state {
        case .waiting:
            return item.direction == .outgoing
                ? String(localized: "Waiting for your Mac…")
                : String(localized: "Preparing…")
        case .transferring:
            return item.direction == .outgoing
                ? String(localized: "Sending to Mac — \(done) of \(total)")
                : String(localized: "Receiving from Mac — \(done) of \(total)")
        case .verifying:
            return String(localized: "Checking the file…")
        case let .completed(location):
            return item.direction == .outgoing
                ? String(localized: "Saved to Downloads on your Mac as “\(location)”")
                : String(localized: "Saved in Files › Glassy Desk › From Mac")
        case .failed(.cancelled, _):
            return String(localized: "Cancelled")
        case let .failed(_, message):
            return message.isEmpty ? String(localized: "The transfer didn't finish.") : message
        }
    }
}

/// A Photos item or dropped file copied into a private folder for sending.
struct OutgoingTransferFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            OutgoingTransferFile(url: try FileTransferCenter.makeTemporaryCopy(
                of: received.file,
                name: received.file.lastPathComponent
            ))
        }
    }
}
