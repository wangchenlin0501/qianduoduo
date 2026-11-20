import CoreData
import Foundation

/// Stable record IDs keep a link useful when a video is renamed or rescheduled.
/// No managed-object URI is synced: those URIs are local to a device's store.
nonisolated struct TodoContentLink: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case video, pool
    }

    let version: Int
    let kind: Kind
    let recordIDs: [UUID]
    let fallbackTitle: String

    init(kind: Kind, recordIDs: [UUID], fallbackTitle: String) {
        version = 1
        self.kind = kind
        var seen: Set<UUID> = []
        self.recordIDs = recordIDs.filter { seen.insert($0).inserted }
        self.fallbackTitle = String(fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    var encodedValue: String? {
        guard isValid else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ raw: String?) -> Self? {
        guard let raw, raw.utf8.count <= 128_000,
              let data = raw.data(using: .utf8),
              let link = try? JSONDecoder().decode(Self.self, from: data), link.isValid else { return nil }
        return link
    }

    private var isValid: Bool {
        version == 1 && !recordIDs.isEmpty && recordIDs.count <= 1_000 &&
            Set(recordIDs).count == recordIDs.count &&
            (kind != .pool || recordIDs.count == 1) &&
            !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            fallbackTitle.count <= 500
    }

    /// The caller supplies records from the todo's exact current space and store.
    /// Deleted anchors never fall back to a similarly named, unrelated video.
    @MainActor
    func resolvedRecords(in records: [AdRecord]) -> [AdRecord] {
        let live = records.filter { !$0.isDeleted && $0.managedObjectContext != nil }
        let anchors = recordIDs.compactMap { id in live.first { $0.id == id } }
        if kind == .pool { return Array(anchors.prefix(1)) }
        guard let anchor = anchors.first(where: Self.isAssignedToVideo) else { return [] }
        return live.filter {
            Self.isAssignedToVideo($0) &&
                Self.videoName($0) == Self.videoName(anchor) &&
                Self.videoDay($0.publishDate) == Self.videoDay(anchor.publishDate)
        }
    }

    @MainActor
    private static func isAssignedToVideo(_ record: AdRecord) -> Bool {
        !(record.videoTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            record.publishDate != nil
    }

    @MainActor
    private static func videoName(_ record: AdRecord) -> String {
        let name = record.videoTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "未命名视频" : name
    }

    private static func videoDay(_ date: Date?) -> Date? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 28_800)!
        return calendar.startOfDay(for: date)
    }
}

extension TodoItem {
    var contentLink: TodoContentLink? { TodoContentLink.decode(linkedContent) }
}
