import Foundation

/// Foreground notifications may arrive together; scan once, and never overlap a running scan.
nonisolated struct CloudShareRepairGate {
    private let minimumInterval: TimeInterval
    private var isRunning = false
    private var lastSuccessfulCompletion: Date?

    init(minimumInterval: TimeInterval = 30) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func begin(at date: Date, force: Bool = false) -> Bool {
        guard !isRunning else { return false }
        if !force, let lastSuccessfulCompletion,
           date.timeIntervalSince(lastSuccessfulCompletion) < minimumInterval { return false }
        isRunning = true
        return true
    }

    mutating func finish(at date: Date, succeeded: Bool) {
        isRunning = false
        lastSuccessfulCompletion = succeeded ? date : nil
    }
}
