import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct PersistenceLoadStateTests {
    @Test func anUnreadableStoreIsReportedWithoutReplacingOrTouchingTheFile() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("QianDuoDuo.sqlite")
        let original = Data("这不是 SQLite 数据库，模拟无法打开的数据文件".utf8) + Data(repeating: 0xAB, count: 4_096)
        try original.write(to: storeURL)

        let persistence = PersistenceController(location: .localFile(storeURL))

        guard case .failed = persistence.loadState else {
            Issue.record("An unreadable store must end in .failed, got \(persistence.loadState)")
            return
        }
        // No empty replacement store was attached, and the user's file is byte-for-byte unchanged.
        #expect(persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        #expect(try Data(contentsOf: storeURL) == original)
    }

    @Test func aHealthyStoreIsReadyAndWritableAsSoonAsTheControllerExists() throws {
        let directory = try Self.makeDirectory()
        let persistence = PersistenceController(location: .localFile(directory.appendingPathComponent("QianDuoDuo.sqlite")))
        let coordinator = persistence.container.persistentStoreCoordinator
        defer {
            persistence.container.viewContext.reset()
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }

        // Callers such as the app delegate use the store right after `shared` is created.
        #expect(persistence.loadState.isReady)
        #expect(coordinator.persistentStores.count == 1)
        let context = persistence.container.viewContext
        let record = AdRecord(context: context)
        record.id = UUID()
        try context.save()
        #expect(try context.fetch(AdRecord.fetchRequest()).count == 1)
    }

    @Test func inMemoryControllersAreReadyImmediately() {
        #expect(PersistenceController(inMemory: true).loadState.isReady)
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreLoad-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
