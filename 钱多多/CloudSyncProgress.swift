import Foundation

nonisolated enum CloudSyncRefreshResult: Equatable, Sendable {
    case waiting
    case receivedUpdates
    case failed(String)

    var message: String {
        switch self {
        case .waiting: "本机已刷新，正在等待 iCloud 更新。"
        case .receivedUpdates: "iCloud 下载检查已完成，其他修改仍会在后台同步。"
        case .failed(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "icloud"
        case .receivedUpdates: "icloud.and.arrow.down"
        case .failed: "exclamationmark.icloud"
        }
    }
}

/// Successful work in one store or direction must not hide a failure in another.
nonisolated struct CloudSyncProgress {
    enum Phase: String, Sendable { case setup, download, upload }

    private struct Failure {
        let date: Date
        let message: String
    }

    private var failures: [String: Failure] = [:]
    private var lastCompletionDates: [String: Date] = [:]
    private(set) var lastImportDate: Date?

    mutating func finish(store: String, phase: Phase, at date: Date, errorMessage: String?) {
        let key = store + "/" + phase.rawValue
        if let lastDate = lastCompletionDates[key], date < lastDate { return }
        lastCompletionDates[key] = date
        if let errorMessage {
            failures[key] = Failure(date: date, message: errorMessage)
        } else {
            failures.removeValue(forKey: key)
            if phase == .download { lastImportDate = max(lastImportDate ?? .distantPast, date) }
        }
    }

    func result(since date: Date) -> CloudSyncRefreshResult {
        if let failure = failures.values.max(by: { $0.date < $1.date }) {
            return .failed(failure.message)
        }
        if let lastImportDate, lastImportDate >= date { return .receivedUpdates }
        return .waiting
    }
}
