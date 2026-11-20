import CloudKit
import Combine
import CoreData
import Foundation

@MainActor
final class CloudSyncRefreshService: ObservableObject {
    static let shared = CloudSyncRefreshService()

    /// Latest sync outcome for display, from a manual refresh or an automatic CloudKit event.
    /// `.receivedUpdates` only means a download check finished; it never means every local change
    /// has been uploaded. An outstanding failure in any store or direction, or paused sharing, is kept
    /// until that same operation succeeds, so a success elsewhere cannot hide it.
    @Published private(set) var lastResult: CloudSyncRefreshResult?
    /// When `lastResult` was determined. Never moves backwards for late, out-of-order events.
    @Published private(set) var lastCheckedAt: Date?

    private var refreshTask: Task<CloudSyncRefreshResult, Never>?
    private var localRefresh = CloudSyncLocalStoreRefresh(since: AppLogger.shared.sessionStartedAt)
    private var progress = CloudSyncProgress()
    private let pausedSharingError: () -> Error?

    /// `pausedSharingError` is injectable so tests do not depend on the app's CloudKit container.
    init(pausedSharingError: (() -> Error?)? = nil) {
        if let pausedSharingError {
            self.pausedSharingError = pausedSharingError
        } else {
            self.pausedSharingError = { PersistenceController.shared.sharingConfigurationError }
        }
    }

    func refresh() async -> CloudSyncRefreshResult {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    func record(_ event: NSPersistentCloudKitContainer.Event) {
        guard let endDate = event.endDate else { return }
        let phase: CloudSyncProgress.Phase
        switch event.type {
        case .setup: phase = .setup
        case .import: phase = .download
        case .export: phase = .upload
        @unknown default: return
        }
        let message = event.error.map(CloudSyncDiagnostics.userMessage(for:)) ??
            (event.succeeded ? nil : "iCloud 尚未完成同步，请稍后重试。")
        recordCompletion(store: event.storeIdentifier, phase: phase, at: endDate, errorMessage: message)
    }

    /// Applies a finished automatic CloudKit operation to the published state.
    /// Failures are always published. A success is published when it is a download, or when it clears
    /// the failure currently shown; an upload or setup success alone says nothing new to the user.
    func recordCompletion(store: String, phase: CloudSyncProgress.Phase, at date: Date, errorMessage: String?) {
        progress.finish(store: store, phase: phase, at: date, errorMessage: errorMessage)
        let current = currentResult(since: .distantPast)
        let showsFailure: Bool
        if case .failed = lastResult { showsFailure = true } else { showsFailure = false }
        switch current {
        case .failed:
            publish(current, at: date)
        case .receivedUpdates where phase == .download || showsFailure:
            publish(current, at: date)
        case .waiting where showsFailure:
            publish(current, at: date)
        default:
            break
        }
    }

    private func performRefresh() async -> CloudSyncRefreshResult {
        let startedAt = Date()
        let persistence = PersistenceController.shared
        AppLogger.shared.log("手动刷新开始：保存本机修改、检查共享、合并本地历史；云端收发由系统调度")
        do {
            let transactions = try localRefresh.refresh(persistence.container.viewContext)
            NotificationCenter.default.post(name: .adRecordsDidChange, object: nil)
            AppLogger.shared.log("手动刷新本地历史：已合并 \(transactions) 个事务")
            if let error = pausedSharingError() {
                return finish(.failed(CloudSyncDiagnostics.userMessage(for: error)))
            }
            let status = try await accountStatus(persistence)
            guard status == .available else {
                let message: String
                switch status {
                case .noAccount: message = "本机已刷新。请在系统设置中登录 iCloud 后再同步。"
                case .restricted: message = "本机已刷新。当前 iCloud 账户受限制，暂时无法同步。"
                default: message = "本机已刷新。暂时无法连接 iCloud，请稍后重试。"
                }
                return finish(.failed(message))
            }
            persistence.repairOwnedShareMembership(force: true)
            persistence.logSyncStoreSummary()

            // Observe actual work for a bounded interval. A local fetch is never proof of cloud sync.
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(250))
                if case .receivedUpdates = currentResult(since: startedAt) { break }
            }
            // A user can open an editor while the cloud check is in flight.
            // Only the initial pull commits changes; do not save newly started edits here.
            if !persistence.container.viewContext.hasChanges {
                _ = try localRefresh.refresh(persistence.container.viewContext)
            }
            NotificationCenter.default.post(name: .adRecordsDidChange, object: nil)
            // Only an import that finished after `startedAt` counts; uploads may still be pending.
            return finish(currentResult(since: startedAt))
        } catch {
            AppLogger.shared.log("手动刷新失败：\(CloudSyncDiagnostics.describe(error))")
            return finish(.failed(CloudSyncDiagnostics.userMessage(for: error)))
        }
    }

    private func currentResult(since date: Date) -> CloudSyncRefreshResult {
        if let error = pausedSharingError() {
            return .failed(CloudSyncDiagnostics.userMessage(for: error))
        }
        return progress.result(since: date)
    }

    private func finish(_ result: CloudSyncRefreshResult) -> CloudSyncRefreshResult {
        AppLogger.shared.log("手动刷新结果：\(result.message)")
        publish(result, at: Date())
        return result
    }

    private func publish(_ result: CloudSyncRefreshResult, at date: Date) {
        if lastResult != result { lastResult = result }
        if let lastCheckedAt, lastCheckedAt >= date { return }
        lastCheckedAt = date
    }

    private func accountStatus(_ persistence: PersistenceController) async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            let request = AccountStatusRequest(continuation)
            request.timeoutTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                request.finish(.failure(URLError(.timedOut)))
            }
            persistence.cloudAccountStatus { status, error in
                Task { @MainActor in
                    if let error { request.finish(.failure(error)) }
                    else { request.finish(.success(status)) }
                }
            }
        }
    }
}

@MainActor
private final class AccountStatusRequest {
    private var continuation: CheckedContinuation<CKAccountStatus, Error>?
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<CKAccountStatus, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<CKAccountStatus, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
