import Foundation
import Testing
@testable import 钱多多

/// The published state the settings screen shows, driven by automatic CloudKit events.
@MainActor
struct CloudSyncRefreshServiceTests {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func anAutomaticFailureIsPublishedWithItsTime() {
        let service = CloudSyncRefreshService(pausedSharingError: { nil })
        service.recordCompletion(store: "private", phase: .upload, at: start, errorMessage: "上传失败")
        #expect(service.lastResult == .failed("上传失败"))
        #expect(service.lastCheckedAt == start)
    }

    @Test func aSuccessElsewhereKeepsTheFailureUntilTheSameOperationSucceeds() {
        let service = CloudSyncRefreshService(pausedSharingError: { nil })
        service.recordCompletion(store: "private", phase: .upload, at: start, errorMessage: "上传失败")
        service.recordCompletion(store: "shared", phase: .download, at: start.addingTimeInterval(5), errorMessage: nil)
        #expect(service.lastResult == .failed("上传失败"))
        #expect(service.lastCheckedAt == start.addingTimeInterval(5))

        service.recordCompletion(store: "private", phase: .upload, at: start.addingTimeInterval(9), errorMessage: nil)
        #expect(service.lastResult == .receivedUpdates)
        #expect(service.lastCheckedAt == start.addingTimeInterval(9))
    }

    @Test func setupAndUploadSuccessesAreNotReportedAsADownloadCheck() {
        let service = CloudSyncRefreshService(pausedSharingError: { nil })
        service.recordCompletion(store: "private", phase: .setup, at: start, errorMessage: nil)
        service.recordCompletion(store: "private", phase: .upload, at: start.addingTimeInterval(1), errorMessage: nil)
        #expect(service.lastResult == nil)
        #expect(service.lastCheckedAt == nil)

        service.recordCompletion(store: "private", phase: .download, at: start.addingTimeInterval(2), errorMessage: nil)
        #expect(service.lastResult == .receivedUpdates)
        #expect(service.lastCheckedAt == start.addingTimeInterval(2))
    }

    @Test func pausedSharingStaysVisibleDespiteSuccessfulDownloads() {
        let paused = CloudSyncConfigurationError.missingSharingEntitlement
        let service = CloudSyncRefreshService(pausedSharingError: { paused })
        service.recordCompletion(store: "private", phase: .download, at: start, errorMessage: nil)
        #expect(service.lastResult == .failed(paused.localizedDescription))
    }

    @Test func aLateOlderEventDoesNotMoveTheCheckTimeBackwards() {
        let service = CloudSyncRefreshService(pausedSharingError: { nil })
        service.recordCompletion(store: "private", phase: .download, at: start.addingTimeInterval(10), errorMessage: nil)
        service.recordCompletion(store: "shared", phase: .upload, at: start, errorMessage: "共享库上传失败")
        #expect(service.lastResult == .failed("共享库上传失败"))
        #expect(service.lastCheckedAt == start.addingTimeInterval(10))
    }
}
