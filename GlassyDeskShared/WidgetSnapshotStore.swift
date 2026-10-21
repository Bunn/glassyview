import Foundation

enum WidgetSnapshotStoreError: Error, Equatable {
    case containerUnavailable
    case snapshotTooLarge
}

/// What a widget found when it looked for the snapshot.
enum WidgetSnapshotReadResult: Equatable, Sendable {
    case snapshot(GlassyDeskWidgetSnapshot)
    /// No usable snapshot: the app hasn't written one, or it is corrupt or from another schema.
    case missing
    /// A snapshot exists but can't be opened right now, for example before the first unlock after a restart.
    case unreadable
}

struct WidgetSnapshotStore: Sendable {
    static let fileName = "widget-snapshot.json"
    static let maximumFileSize = 256 * 1_024

    private let directoryURL: URL?

    init(directoryURL: URL?) {
        self.directoryURL = directoryURL
    }

    static func appGroup() -> Self {
        Self(directoryURL: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GlassyDeskAppGroup.identifier
        ))
    }

    func read() -> GlassyDeskWidgetSnapshot? {
        if case .snapshot(let snapshot) = load() { return snapshot }
        return nil
    }

    func load() -> WidgetSnapshotReadResult {
        guard let fileURL else { return .unreadable }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        guard data.count <= Self.maximumFileSize,
              let snapshot = try? Self.decoder.decode(GlassyDeskWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == GlassyDeskWidgetSnapshot.currentSchemaVersion else {
            return .missing
        }
        return .snapshot(snapshot)
    }

    func write(_ snapshot: GlassyDeskWidgetSnapshot) throws {
        guard let directoryURL, let fileURL else {
            throw WidgetSnapshotStoreError.containerUnavailable
        }

        let data = try Self.encoder.encode(snapshot)
        guard data.count <= Self.maximumFileSize else {
            throw WidgetSnapshotStoreError.snapshotTooLarge
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        // Widgets refresh while the device is locked. With a "complete" protection class they
        // can't open the file then, and showed "No saved Macs" until the app was opened again.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var fileURL: URL? {
        directoryURL?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
