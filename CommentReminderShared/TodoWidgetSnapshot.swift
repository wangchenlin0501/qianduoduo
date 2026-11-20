import Foundation

// Compiled into both targets: the widget reads this small snapshot, never the app's stores.
nonisolated struct TodoWidgetSnapshot: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ready
        case unavailable
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let title: String
        // Retained for old cache compatibility; current readers write empty and views ignore it.
        let notes: String
        let dueDate: Date?
        var recordURI: String? = nil
        var canComplete: Bool = false
        // Optional so snapshots written before linked-content labels remain readable.
        var linkedContentTitle: String? = nil
    }

    let status: Status
    let generatedAt: Date
    let spaceName: String?
    let pendingCount: Int
    let items: [Item]
    let themeHex: String
    let lightAccentHex: String
    let darkAccentHex: String
    var spaceURI: String? = nil
    var actionMessage: String? = nil

    static let kind = "TodoListWidget"
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "QDDAppGroupIdentifier") as? String ?? "group.com.example.qianduoduo"
    static let destinationURL = URL(string: "qianduoduo://todo")!

    static let placeholder = TodoWidgetSnapshot(
        status: .ready,
        generatedAt: Date(),
        spaceName: nil,
        pendingCount: 3,
        items: [
            Item(id: UUID(uuidString: "67EBCEDA-66A9-41F8-99A9-8ED091019E21")!, title: "确认拍摄安排", notes: "", dueDate: nil),
            Item(id: UUID(uuidString: "DD6597E0-36D1-43A3-8A49-B3AF7FD39EB2")!, title: "整理本月账本", notes: "", dueDate: nil),
            Item(id: UUID(uuidString: "801DBA08-F0F9-4B17-A47C-775C6470B6E3")!, title: "跟进合作进度", notes: "", dueDate: nil)
        ],
        themeHex: "8B5E3C",
        lightAccentHex: "8B5E3C",
        darkAccentHex: "C9A47F"
    )

    static let unavailable = TodoWidgetSnapshot(
        status: .unavailable,
        generatedAt: Date(),
        spaceName: nil,
        pendingCount: 0,
        items: [],
        themeHex: "8B5E3C",
        lightAccentHex: "8B5E3C",
        darkAccentHex: "C9A47F"
    )
}

nonisolated enum TodoWidgetSnapshotFile {
    private static let filename = "todo-widget-snapshot.json"
    private static let maximumByteCount = 256 * 1_024

    static func read() -> TodoWidgetSnapshot? {
        guard let directory = sharedDirectory() else { return nil }
        return read(from: directory)
    }

    static func read(from directory: URL) -> TodoWidgetSnapshot? {
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            // A bounded read avoids allocating an unbounded payload or accessing file timestamps.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= maximumByteCount {
                guard let chunk = try handle.read(upToCount: maximumByteCount + 1 - data.count),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard !data.isEmpty, data.count <= maximumByteCount else { return nil }
            let snapshot = try JSONDecoder().decode(TodoWidgetSnapshot.self, from: data)
            return isValid(snapshot) ? snapshot : nil
        } catch {
            // Missing, unreadable and malformed snapshots are unavailable, not an empty ready list.
            return nil
        }
    }

    static func write(_ snapshot: TodoWidgetSnapshot, to directory: URL) throws {
        guard isValid(snapshot) else { throw SnapshotError.invalidSnapshot }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumByteCount else { throw SnapshotError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        #if os(iOS)
        // Keep a complete snapshot available to the widget after the device's first unlock.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    static func sharedDirectory() -> URL? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TodoWidgetSnapshot.appGroupID)
        #else
        nil
        #endif
    }

    private static func isValid(_ snapshot: TodoWidgetSnapshot) -> Bool {
        guard snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.pendingCount >= snapshot.items.count,
              snapshot.items.count <= 20,
              snapshot.spaceName.map({ $0.count <= 2_000 }) ?? true,
              snapshot.spaceURI.map(isCoreDataURI) ?? true,
              snapshot.actionMessage.map({ $0.count <= 1_000 }) ?? true,
              isHexColor(snapshot.themeHex),
              isHexColor(snapshot.lightAccentHex),
              isHexColor(snapshot.darkAccentHex) else { return false }

        if snapshot.status == .unavailable {
            return snapshot.pendingCount == 0 && snapshot.items.isEmpty
                && snapshot.spaceName == nil && snapshot.spaceURI == nil
        }
        guard snapshot.pendingCount == 0 || !snapshot.items.isEmpty else { return false }

        var seenIDs = Set<UUID>()
        for item in snapshot.items {
            guard seenIDs.insert(item.id).inserted,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.count <= 2_000,
                  item.notes.count <= 20_000,
                  item.linkedContentTitle.map({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 800
                  }) ?? true,
                  item.dueDate.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { return false }
            if item.canComplete {
                guard snapshot.spaceURI != nil,
                      let recordURI = item.recordURI,
                      isCoreDataURI(recordURI) else { return false }
            }
        }
        return true
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func isCoreDataURI(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "x-coredata",
              let host = url.host, !host.isEmpty,
              url.pathComponents.filter({ $0 != "/" }).count >= 2,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        return true
    }

    private enum SnapshotError: Error {
        case invalidSnapshot
    }
}
