import CoreData
import Foundation

/// Presents changes already imported into the local store; it does not download from CloudKit.
@MainActor
final class CloudSyncLocalStoreRefresh {
    private let maximumTransactions: Int
    private let historyStartDate: Date?
    private var tokens: [String: NSPersistentHistoryToken] = [:]
    private weak var refreshedContext: NSManagedObjectContext?
    private var nextStoreIndex = 0

    init(maximumTransactions: Int = 64, since date: Date? = nil) {
        self.maximumTransactions = max(1, min(maximumTransactions, 128))
        historyStartDate = date
    }

    /// Saves pending edits and returns the number of local history transactions merged this time.
    /// A bounded batch leaves its last token in memory so another refresh can continue.
    func refresh(_ context: NSManagedObjectContext) throws -> Int {
        context.processPendingChanges()
        if context.hasChanges {
            // On failure leave the edits intact and do not advance any history token.
            try context.save()
        }

        if refreshedContext !== context {
            refreshedContext = context
            tokens.removeAll()
            nextStoreIndex = 0
        }

        let stores = context.persistentStoreCoordinator?.persistentStores.filter { store in
            store.type == NSSQLiteStoreType &&
                (store.options?[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue == true
        } ?? []
        var mergedCount = 0

        if !stores.isEmpty {
            let firstIndex = nextStoreIndex % stores.count
            // Alternate the first store so a large history cannot starve another store.
            nextStoreIndex = (firstIndex + 1) % stores.count
            for offset in stores.indices {
                let remaining = maximumTransactions - mergedCount
                guard remaining > 0 else { break }
                let store = stores[(firstIndex + offset) % stores.count]
                let transactions: [NSPersistentHistoryTransaction]
                do {
                    transactions = try history(in: store, context: context, limit: remaining)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    error.code == NSPersistentHistoryTokenExpiredError {
                    // Pruned history invalidates a token, but must never lead to clearing app data.
                    tokens.removeValue(forKey: store.identifier)
                    transactions = try history(in: store, context: context, limit: remaining)
                }

                for transaction in transactions {
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: transaction.objectIDNotification().userInfo ?? [:],
                        into: [context]
                    )
                    tokens[store.identifier] = transaction.token
                    mergedCount += 1
                }
            }
        }

        // Preserve registered object identities and any edits; reset() would invalidate them.
        context.refreshAllObjects()
        context.processPendingChanges()
        return mergedCount
    }

    private func history(
        in store: NSPersistentStore,
        context: NSManagedObjectContext,
        limit: Int
    ) throws -> [NSPersistentHistoryTransaction] {
        let request: NSPersistentHistoryChangeRequest
        if let token = tokens[store.identifier] {
            request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        } else if let historyStartDate {
            request = NSPersistentHistoryChangeRequest.fetchHistory(after: historyStartDate)
        } else {
            request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
        }
        request.affectedStores = [store]
        request.resultType = .transactionsAndChanges
        guard let entity = NSPersistentHistoryTransaction.entityDescription(with: context) else { return [] }
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>()
        fetchRequest.entity = entity
        fetchRequest.fetchLimit = limit
        request.fetchRequest = fetchRequest
        let result = try context.execute(request) as? NSPersistentHistoryResult
        let transactions = result?.result as? [NSPersistentHistoryTransaction] ?? []
        // Some OS versions ignore history fetchLimit. Cap merges ourselves and advance only
        // to the last consumed transaction. Sort its public value, not an internal store key.
        return Array(transactions.sorted { $0.transactionNumber < $1.transactionNumber }.prefix(limit))
    }
}
