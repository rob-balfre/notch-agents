import Foundation

public enum StatusFileLocation {
    public static var directoryURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        return baseURL.appendingPathComponent("NotchAgents", isDirectory: true)
    }

    public static var snapshotURL: URL {
        directoryURL.appendingPathComponent("status.json")
    }
}

public enum StatusSnapshotStore {
    public static func load(at url: URL = StatusFileLocation.snapshotURL) throws -> StatusSnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(StatusSnapshot.self, from: data)
    }

    public static func loadIfPresent(
        at url: URL = StatusFileLocation.snapshotURL
    ) throws -> StatusSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try load(at: url)
    }

    public static func save(
        _ snapshot: StatusSnapshot,
        at url: URL = StatusFileLocation.snapshotURL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public static func ensureStatusFile(
        at url: URL = StatusFileLocation.snapshotURL
    ) throws -> URL {
        if try loadIfPresent(at: url) == nil {
            try save(.empty, at: url)
        }

        return url
    }

    public static func mutate(
        at url: URL = StatusFileLocation.snapshotURL,
        _ change: (inout StatusSnapshot) -> Void
    ) throws {
        var snapshot = try loadIfPresent(at: url) ?? .empty
        change(&snapshot)
        snapshot.updatedAt = .now
        try save(snapshot, at: url)
    }

    public static func prettyPrinted(
        _ snapshot: StatusSnapshot
    ) throws -> String {
        let data = try encoder.encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
