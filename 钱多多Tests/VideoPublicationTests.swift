import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct VideoPublicationTests {
    @Test func addingBrandPreservesPublishedVideoAndCommentState() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let date = dayOnly(Date())
        let publishedAt = Date().addingTimeInterval(-3_600)
        let completedAt = publishedAt.addingTimeInterval(600)
        let existing = AdRecord(context: context)
        existing.id = UUID()
        existing.videoTitle = "已发布视频"
        existing.publishDate = date
        existing.publishedDate = publishedAt
        existing.commentReminderID = "existing-publication"
        existing.brandCommentedAt = completedAt
        existing.statusValue = .paid
        let added = AdRecord(context: context)
        added.id = UUID()
        try context.save()

        let publication = try #require(existingVideoPublication(
            name: "已发布视频", date: date, in: [existing, added], excluding: added.objectID
        ))
        prepareRecordsForVideo([added], name: "已发布视频", date: date, publication: publication)
        try context.save()
        #expect([existing, added].allSatisfy { $0.publishedDate != nil })
        #expect(added.publishedDate == publishedAt)
        #expect(added.commentReminderID == "existing-publication")
        #expect(added.brandCommentedAt == completedAt)
        #expect(existing.statusValue == .paid)
        #expect(added.statusValue == .unpaid)
    }

    @Test func scheduledVideoRemainsUnpublished() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let date = dayOnly(Date())
        let existing = AdRecord(context: context)
        existing.id = UUID()
        existing.videoTitle = "待发布视频"
        existing.publishDate = date
        let added = AdRecord(context: context)
        let publication = existingVideoPublication(name: "待发布视频", date: date, in: [existing])
        prepareRecordsForVideo([added], name: "待发布视频", date: date, publication: publication)
        #expect(publication == nil)
        #expect(added.publishedDate == nil)
        #expect(added.commentReminderID == nil)
        #expect(added.brandCommentedAt == nil)
    }

    @Test func legacyPublicationWithoutScheduledDateKeepsItsIdentity() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let existing = AdRecord(context: context)
        existing.id = UUID()
        existing.videoTitle = "旧视频"
        existing.publishedDate = Date().addingTimeInterval(-600)
        existing.syncSpace = try persistence.activeSyncSpace(in: context)
        let added = AdRecord(context: context)
        added.syncSpace = existing.syncSpace
        let expectedID = try #require(CommentReminderStore.eventID(for: existing))
        let publication = try #require(existingVideoPublication(name: "旧视频", date: nil, in: [existing]))
        prepareRecordsForVideo([added], name: "旧视频", date: nil, publication: publication)
        #expect(added.publishedDate == existing.publishedDate)
        #expect(CommentReminderStore.eventID(for: added) == expectedID)
    }

    @Test func lookupExcludesTheEditedRecordAndOtherDates() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let date = dayOnly(Date())
        let tomorrow = date.addingTimeInterval(86_400)
        let edited = AdRecord(context: context)
        edited.id = UUID()
        edited.videoTitle = "同名视频"
        edited.publishDate = date
        edited.publishedDate = Date()
        let other = AdRecord(context: context)
        other.id = UUID()
        other.videoTitle = "同名视频"
        other.publishDate = tomorrow
        other.publishedDate = Date()
        try context.save()
        #expect(existingVideoPublication(
            name: "同名视频", date: date, in: [edited, other], excluding: edited.objectID
        ) == nil)
    }
}
