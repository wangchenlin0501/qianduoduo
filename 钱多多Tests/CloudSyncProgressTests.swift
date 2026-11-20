import Foundation
import Testing
@testable import 钱多多

struct CloudSyncProgressTests {
    @Test func aLocalRefreshIsNotCloudSuccess() {
        #expect(CloudSyncProgress().result(since: .distantPast) == .waiting)
    }

    @Test func importingOneStoreDoesNotHideAnotherStoresUploadFailure() {
        var progress = CloudSyncProgress()
        progress.finish(store: "private", phase: .upload, at: Date(), errorMessage: "部分数据未同步")
        progress.finish(store: "shared", phase: .download, at: Date(), errorMessage: nil)
        #expect(progress.result(since: .distantPast) == .failed("部分数据未同步"))
        progress.finish(store: "private", phase: .upload, at: Date(), errorMessage: nil)
        #expect(progress.result(since: .distantPast) == .receivedUpdates)
    }

    @Test func previousImportsDoNotProveTheCurrentRefreshCompleted() {
        var progress = CloudSyncProgress()
        let start = Date()
        progress.finish(store: "shared", phase: .download, at: start.addingTimeInterval(-10), errorMessage: nil)
        #expect(progress.result(since: start) == .waiting)
        progress.finish(store: "shared", phase: .upload, at: start, errorMessage: nil)
        #expect(progress.result(since: start) == .waiting)
    }

    @Test func delayedOldSuccessCannotClearANewerFailure() {
        var progress = CloudSyncProgress()
        let start = Date()
        progress.finish(store: "private", phase: .upload, at: start, errorMessage: "新上传失败")
        progress.finish(store: "private", phase: .upload, at: start.addingTimeInterval(-1), errorMessage: nil)
        #expect(progress.result(since: start) == .failed("新上传失败"))
    }

    @Test func anOlderImportInAnotherStoreCannotMoveTheDownloadDateBackwards() {
        var progress = CloudSyncProgress()
        let start = Date()
        progress.finish(store: "private", phase: .download, at: start, errorMessage: nil)
        progress.finish(store: "shared", phase: .download, at: start.addingTimeInterval(-1), errorMessage: nil)
        #expect(progress.result(since: start) == .receivedUpdates)
    }
}
