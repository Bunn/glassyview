import Foundation

enum WidgetSnapshotStoreError: Error, Equatable {
    case containerUnavailable
    case snapshotTooLarge
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
        guard let fileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= Self.maximumFileSize,
              let snapshot = try? Self.decoder.decode(GlassyDeskWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == GlassyDeskWidgetSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
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
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
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
