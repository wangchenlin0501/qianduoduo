import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct TodoContentLinkTests {
    @Test func payloadValidatesVersionKindBoundsAndStableUUIDs() throws {
        let id = UUID()
        let link = TodoContentLink(kind: .video, recordIDs: [id, id], fallbackTitle: " 视频 ")
        #expect(link.recordIDs == [id])
        #expect(link.fallbackTitle == "视频")
        let value = try #require(link.encodedValue)
        #expect(TodoContentLink.decode(value) == link)
        #expect(TodoContentLink.decode(nil) == nil)
        #expect(TodoContentLink.decode("not-json") == nil)
        #expect(TodoContentLink.decode(value.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")) == nil)
        #expect(TodoContentLink.decode(value.replacingOccurrences(of: "\"video\"", with: "\"unknown\"")) == nil)
        #expect(TodoContentLink(kind: .video, recordIDs: [], fallbackTitle: "视频").encodedValue == nil)
        #expect(TodoContentLink(kind: .pool, recordIDs: [id, UUID()], fallbackTitle: "品牌").encodedValue == nil)
        #expect(TodoContentLink(kind: .pool, recordIDs: [id], fallbackTitle: "  ").encodedValue == nil)
    }

    @Test func videoAssociationFollowsRenameRescheduleAndSurvivingAnchorWithoutTitleFallback() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let first = record(in: context, title: "原视频", brand: "品牌一")
        let second = record(in: context, title: "原视频", brand: "品牌二")
        let unrelated = record(in: context, title: "原视频", brand: "同名另一日")
        unrelated.publishDate = Date(timeIntervalSince1970: 1_800_000_000)
        try context.save()
        let link = TodoContentLink(kind: .video, recordIDs: [try #require(first.id), try #require(second.id)],
                                   fallbackTitle: "原视频")
        #expect(Set(link.resolvedRecords(in: [first, second, unrelated]).map(\.objectID)) == Set([first.objectID, second.objectID]))
        first.videoTitle = "改名视频"
        second.videoTitle = "改名视频"
        first.publishDate = unrelated.publishDate
        second.publishDate = unrelated.publishDate
        try context.save()
        #expect(Set(link.resolvedRecords(in: [first, second, unrelated]).map(\.objectID)) == Set([first.objectID, second.objectID]))
        context.delete(first)
        try context.save()
        #expect(link.resolvedRecords(in: [first, second, unrelated]).map(\.objectID) == [second.objectID])
        context.delete(second)
        try context.save()
        #expect(link.resolvedRecords(in: [first, second, unrelated]).isEmpty)
    }

    @Test func poolAssociationFollowsRecordIntoVideoButDeletedRecordStaysUnavailable() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let original = record(in: context, title: nil, brand: "品牌")
        let sameName = record(in: context, title: nil, brand: "品牌")
        try context.save()
        let link = TodoContentLink(kind: .pool, recordIDs: [try #require(original.id)], fallbackTitle: "品牌")
        original.videoTitle = "安排后的新视频"
        try context.save()
        #expect(link.resolvedRecords(in: [original, sameName]).map(\.objectID) == [original.objectID])
        context.delete(original)
        try context.save()
        #expect(link.resolvedRecords(in: [original, sameName]).isEmpty)
    }

    private func record(in context: NSManagedObjectContext, title: String?, brand: String) -> AdRecord {
        let record = AdRecord(context: context)
        record.id = UUID()
        record.videoTitle = title
        record.brandName = brand
        return record
    }
}
