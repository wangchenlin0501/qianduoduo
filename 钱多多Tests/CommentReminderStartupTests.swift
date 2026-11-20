import CoreData
import Foundation
import Testing
@testable import 钱多多

struct CloudShareRepairGateTests {
    @Test func launchSignalsShareOneInFlightScanAndForegroundSignalsUseCooldown() {
        var gate = CloudShareRepairGate(minimumInterval: 30)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let firstScanStarted = gate.begin(at: start)
        let overlappingScanStarted = gate.begin(at: start.addingTimeInterval(1))
        let overlappingManualScanStarted = gate.begin(at: start.addingTimeInterval(2), force: true)
        #expect(firstScanStarted)
        #expect(!overlappingScanStarted)
        #expect(!overlappingManualScanStarted)
        gate.finish(at: start.addingTimeInterval(3), succeeded: true)
        let scanDuringCooldownStarted = gate.begin(at: start.addingTimeInterval(10))
        let scanAfterCooldownStarted = gate.begin(at: start.addingTimeInterval(33))
        #expect(!scanDuringCooldownStarted)
        #expect(scanAfterCooldownStarted)
    }

    @Test func manualRefreshBypassesCooldownAndFailureDoesNotSuppressRetry() {
        var gate = CloudShareRepairGate(minimumInterval: 30)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let firstScanStarted = gate.begin(at: start)
        #expect(firstScanStarted)
        gate.finish(at: start, succeeded: true)
        let manualScanStarted = gate.begin(at: start.addingTimeInterval(1), force: true)
        #expect(manualScanStarted)
        gate.finish(at: start.addingTimeInterval(2), succeeded: false)
        let retryAfterFailureStarted = gate.begin(at: start.addingTimeInterval(3))
        #expect(retryAfterFailureStarted)

        var failedFirstScan = CloudShareRepairGate(minimumInterval: 30)
        let failedScanStarted = failedFirstScan.begin(at: start)
        #expect(failedScanStarted)
        failedFirstScan.finish(at: start, succeeded: false)
        let failedScanRetried = failedFirstScan.begin(at: start.addingTimeInterval(1))
        #expect(failedScanRetried)
    }
}

@MainActor
struct CommentReminderStartupTests {
    @Test func projectedReadPreservesLegacyIDsForRecordsWithoutASharedSpace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let record = fixture.makeRecord(title: "待评论", reminderID: nil)
        record.setValue(Data([1, 2, 3]), forKey: "photoData")
        try fixture.context.save()

        let events = try CommentReminderStore.projectedEvents(in: fixture.context, calendar: calendar)

        #expect(events.count == 1)
        #expect(events.first?.id == "legacy-ff7608acab46986e425b7a34d20de0d1d56658c6faca3033dbb03c45d1d33852")
        #expect(events.first?.videoName == "待评论")
    }

    @Test func projectedReadDoesNotCommitOrIncludeUnfinishedEdits() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let record = fixture.makeRecord(title: "saved title", reminderID: "saved-publication")
        try fixture.context.save()
        record.setValue("unfinished title", forKey: "videoTitle")
        _ = fixture.makeRecord(title: "unsaved new record", reminderID: "not-saved")

        let events = try CommentReminderStore.projectedEvents(in: fixture.context, calendar: calendar)

        #expect(fixture.context.hasChanges)
        #expect(record.value(forKey: "videoTitle") as? String == "unfinished title")
        #expect(events.count == 1)
        #expect(events.first?.videoName == "saved title")
    }

    @Test func projectedReadUsesThePersistedRelationshipUUIDAndKeepsUnscopedRecords() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let space = NSEntityDescription.insertNewObject(forEntityName: "SyncSpace", into: fixture.context)
        space.setValue(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!, forKey: "id")
        let scoped = fixture.makeRecord(title: "待评论", reminderID: nil)
        scoped.setValue(space, forKey: "syncSpace")
        _ = fixture.makeRecord(title: "待评论", reminderID: nil)
        try fixture.context.save()

        let events = try CommentReminderStore.projectedEvents(in: fixture.context, calendar: calendar)

        #expect(events.count == 2)
        let ids = Set(events.map(\.id))
        #expect(ids.contains("legacy-ff7608acab46986e425b7a34d20de0d1d56658c6faca3033dbb03c45d1d33852"))
        #expect(ids.contains("legacy-b04db6714e7f15139cd09be7f4293181ee3f139a5f606b6fb34199fb44c80b1d"))
    }

    @Test func projectedReadKeepsGroupCompletionAndLatestMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = fixture.makeRecord(title: "old title", reminderID: "same-publication")
        first.setValue(Date(timeIntervalSinceReferenceDate: 20_000), forKey: "updatedAt")
        first.setValue(Date(timeIntervalSinceReferenceDate: 21_000), forKey: "brandCommentedAt")
        let latest = fixture.makeRecord(title: "latest title", reminderID: "same-publication")
        latest.setValue(Date(timeIntervalSinceReferenceDate: 22_000), forKey: "updatedAt")
        try fixture.context.save()

        let events = try CommentReminderStore.projectedEvents(in: fixture.context, calendar: calendar)

        #expect(events.count == 1)
        #expect(events.first?.id == "same-publication")
        #expect(events.first?.videoName == "latest title")
        #expect(events.first?.completedAt == Date(timeIntervalSinceReferenceDate: 21_000))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    private final class Fixture {
        let coordinator: NSPersistentStoreCoordinator
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReminderStartup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = NSEntityDescription()
            record.name = "AdRecord"
            record.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            let space = NSEntityDescription()
            space.name = "SyncSpace"
            space.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
                let property = NSAttributeDescription()
                property.name = name
                property.attributeType = type
                property.isOptional = true
                return property
            }
            record.properties = [
                attribute("commentReminderID", .stringAttributeType),
                attribute("videoTitle", .stringAttributeType),
                attribute("publishDate", .dateAttributeType),
                attribute("dueDate", .dateAttributeType),
                attribute("updatedAt", .dateAttributeType),
                attribute("brandCommentedAt", .dateAttributeType),
                attribute("photoData", .binaryDataAttributeType)
            ]
            space.properties = [attribute("id", .UUIDAttributeType)]
            let relationship = NSRelationshipDescription()
            relationship.name = "syncSpace"
            relationship.destinationEntity = space
            relationship.minCount = 0
            relationship.maxCount = 1
            relationship.isOptional = true
            record.properties.append(relationship)
            let model = NSManagedObjectModel()
            model.entities = [record, space]
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil,
                at: directory.appendingPathComponent("reminders.sqlite"), options: nil
            )
            context.persistentStoreCoordinator = coordinator
        }

        func makeRecord(title: String, reminderID: String?) -> NSManagedObject {
            let record = NSEntityDescription.insertNewObject(forEntityName: "AdRecord", into: context)
            record.setValue(title, forKey: "videoTitle")
            record.setValue(reminderID, forKey: "commentReminderID")
            record.setValue(Date(timeIntervalSinceReferenceDate: 12_345), forKey: "dueDate")
            return record
        }

        func close() {
            context.reset()
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
