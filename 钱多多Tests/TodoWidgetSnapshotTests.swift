import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import TodoWidgetSnapshotTestSupport
#else
@testable import 钱多多
#endif

struct TodoWidgetSnapshotTests {
    @Test func snapshotRoundTripPreservesChineseContentScopeAndDates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        let dueDate = Date(timeIntervalSince1970: 1_800_086_400.5)
        let snapshot = makeSnapshot(
            generatedAt: generatedAt,
            spaceName: "共享空间：拍摄与回款",
            pendingCount: 7,
            items: [.init(id: UUID(), title: "确认开票抬头 🧾", notes: "客户已确认\n明天下午跟进", dueDate: dueDate)]
        )

        try TodoWidgetSnapshotFile.write(snapshot, to: directory)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == snapshot)
    }

    @Test func switchingToAnEmptySpaceReplacesOldSpaceContents() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try TodoWidgetSnapshotFile.write(makeSnapshot(spaceName: "空间甲", pendingCount: 1, items: [
            .init(id: UUID(), title: "只属于空间甲", notes: "不可泄露到其他空间", dueDate: nil)
        ]), to: directory)

        let emptySpace = makeSnapshot(spaceName: "空间乙", pendingCount: 0, items: [])
        try TodoWidgetSnapshotFile.write(emptySpace, to: directory)
        let actual = try #require(TodoWidgetSnapshotFile.read(from: directory))
        #expect(actual == emptySpace)
        #expect(actual.status == .ready)
        #expect(actual.items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let rawFile = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!rawFile.contains("只属于空间甲"))
        #expect(!rawFile.contains("不可泄露到其他空间"))
    }

    @Test func unavailableReplacesPreviouslyPublishedContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try TodoWidgetSnapshotFile.write(makeSnapshot(spaceName: "已离开的共享空间", pendingCount: 1, items: [
            .init(id: UUID(), title: "旧内容", notes: "", dueDate: nil)
        ]), to: directory)
        try TodoWidgetSnapshotFile.write(.unavailable, to: directory)
        let actual = try #require(TodoWidgetSnapshotFile.read(from: directory))
        #expect(actual.status == .unavailable)
        #expect(actual.spaceName == nil)
        #expect(actual.pendingCount == 0)
        #expect(actual.items.isEmpty)
    }

    @Test func completionRoutingAndActionFeedbackSurviveFileRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = TodoWidgetSnapshot.Item(id: UUID(), title: "待确认事项", notes: "", dueDate: nil)
        item.recordURI = "x-coredata://CC72B17B-57BB-47F1-90A5-96CFDEAB0692/TodoItem/p18"
        item.canComplete = true
        var snapshot = makeSnapshot(spaceName: "当前共享空间", pendingCount: 1, items: [item])
        snapshot.spaceURI = "x-coredata://CC72B17B-57BB-47F1-90A5-96CFDEAB0692/SyncSpace/p1"
        snapshot.actionMessage = "请稍后重试"
        try TodoWidgetSnapshotFile.write(snapshot, to: directory)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == snapshot)
    }

    @Test func linkedContentRoundTripsAndOldSnapshotsWithoutItRemainReadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = TodoWidgetSnapshot.Item(id: UUID(), title: "跟进合作", notes: "历史备注", dueDate: nil)
        item.linkedContentTitle = "池子 · 森达 SENDA"
        let snapshot = makeSnapshot(pendingCount: 1, items: [item])
        try TodoWidgetSnapshotFile.write(snapshot, to: directory)
        #expect(TodoWidgetSnapshotFile.read(from: directory)?.items.first?.linkedContentTitle == "池子 · 森达 SENDA")

        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var items = try #require(legacy["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "linkedContentTitle")
        legacy["items"] = items
        let file = directory.appendingPathComponent("todo-widget-snapshot.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)
        let decoded = try #require(TodoWidgetSnapshotFile.read(from: directory))
        #expect(decoded.items.first?.linkedContentTitle == nil)
        #expect(decoded.items.first?.notes == "历史备注")
    }

    @Test func linkedLabelsMustBeBoundedAndNonemptyWhenPresent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for invalid in ["", " \n ", String(repeating: "长", count: 801)] {
            var item = TodoWidgetSnapshot.Item(id: UUID(), title: "检查关联标签", notes: "", dueDate: nil)
            item.linkedContentTitle = invalid
            let snapshot = makeSnapshot(pendingCount: 1, items: [item])
            #expect(throws: (any Error).self) {
                try TodoWidgetSnapshotFile.write(snapshot, to: directory)
            }
            let file = directory.appendingPathComponent("todo-widget-snapshot.json")
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        }
    }

    @Test func completableItemsRequireValidRecordAndSpaceURIs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("todo-widget-snapshot.json")
        var item = TodoWidgetSnapshot.Item(id: UUID(), title: "不可错误勾选", notes: "", dueDate: nil)
        item.canComplete = true
        var snapshot = makeSnapshot(pendingCount: 1, items: [item])
        snapshot.spaceURI = "x-coredata://CC72B17B-57BB-47F1-90A5-96CFDEAB0692/SyncSpace/p1"
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)

        item.recordURI = "x-coredata://CC72B17B-57BB-47F1-90A5-96CFDEAB0692/TodoItem/p18"
        let missingSpace = makeSnapshot(pendingCount: 1, items: [item])
        try JSONEncoder().encode(missingSpace).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)

        for invalid in ["", "https://example.com/TodoItem/p18", "x-coredata:///TodoItem/p18", "x-coredata://store"] {
            item.recordURI = invalid
            snapshot = makeSnapshot(pendingCount: 1, items: [item])
            snapshot.spaceURI = "x-coredata://CC72B17B-57BB-47F1-90A5-96CFDEAB0692/SyncSpace/p1"
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        }
    }

    @Test func missingMalformedAndSemanticallyInvalidFilesAreUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        let file = directory.appendingPathComponent("todo-widget-snapshot.json")
        try Data("{broken".utf8).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)

        // A syntactically valid document can still claim an impossible pending count.
        let inconsistent = makeSnapshot(pendingCount: 0, items: [
            .init(id: UUID(), title: "一条实际记录", notes: "", dueDate: nil)
        ])
        try JSONEncoder().encode(inconsistent).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        try JSONEncoder().encode(makeSnapshot(pendingCount: -1, items: [])).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        try JSONEncoder().encode(makeSnapshot(pendingCount: 1, items: [])).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
    }

    @Test func duplicateIDsAndOversizedFilesAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("todo-widget-snapshot.json")
        let id = UUID()
        let duplicateIDs = makeSnapshot(pendingCount: 2, items: [
            .init(id: id, title: "第一条", notes: "", dueDate: nil),
            .init(id: id, title: "第二条", notes: "", dueDate: nil)
        ])
        try JSONEncoder().encode(duplicateIDs).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
        #expect(throws: (any Error).self) {
            try TodoWidgetSnapshotFile.write(duplicateIDs, to: directory)
        }

        try Data(repeating: 32, count: 256 * 1_024 + 1).write(to: file, options: .atomic)
        #expect(TodoWidgetSnapshotFile.read(from: directory) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-widget-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        spaceName: String? = nil,
        pendingCount: Int,
        items: [TodoWidgetSnapshot.Item]
    ) -> TodoWidgetSnapshot {
        TodoWidgetSnapshot(
            status: .ready,
            generatedAt: generatedAt,
            spaceName: spaceName,
            pendingCount: pendingCount,
            items: items,
            themeHex: "8B5E3C",
            lightAccentHex: "8B5E3C",
            darkAccentHex: "C9A47F"
        )
    }
}
