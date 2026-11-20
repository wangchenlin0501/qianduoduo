import CoreData
import Foundation
import UIKit
import WidgetKit

private actor TodoWidgetFileWriter {
    func write(_ snapshot: TodoWidgetSnapshot) throws {
        guard let directory = TodoWidgetSnapshotFile.sharedDirectory() else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let saved = TodoWidgetSnapshotFile.read(from: directory) {
            let previous = TodoWidgetSnapshot(
                status: saved.status, generatedAt: snapshot.generatedAt,
                spaceName: saved.spaceName, pendingCount: saved.pendingCount, items: saved.items,
                themeHex: saved.themeHex, lightAccentHex: saved.lightAccentHex,
                darkAccentHex: saved.darkAccentHex, spaceURI: saved.spaceURI,
                actionMessage: saved.actionMessage
            )
            if previous == snapshot { return }
        }
        try TodoWidgetSnapshotFile.write(snapshot, to: directory)
        WidgetCenter.shared.reloadTimelines(ofKind: TodoWidgetSnapshot.kind)
    }
}

/// Lives with the app, including while a widget intent runs without an open scene.
@MainActor
final class TodoWidgetBridge {
    static let shared = TodoWidgetBridge()
    private var persistence: PersistenceController?
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var runningTask: Task<Void, Error>?
    private var needsAnotherPass = false
    private var actionMessage: String?
    private let writer = TodoWidgetFileWriter()

    func configure(persistence: PersistenceController) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        let coordinator = persistence.container.persistentStoreCoordinator
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
        ) { [weak self] note in
            guard let context = note.object as? NSManagedObjectContext,
                  context.persistentStoreCoordinator === coordinator else { return }
            let affectsSnapshot = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                (note.userInfo?[key] as? Set<NSManagedObject>)?.contains {
                    $0.entity.name == "TodoItem" || $0.entity.name == "SyncSpace" || $0.entity.name == "AdRecord"
                } == true
            }
            guard affectsSnapshot else { return }
            // A save must never synchronously wait for the main queue.
            Task { @MainActor [weak self] in self?.requestRefresh() }
        })
        for name in [Notification.Name.NSPersistentStoreRemoteChange, .adRecordsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: persistence.container, queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            Task { @MainActor [weak self] in self?.requestRefresh() }
        })
        requestRefresh()
    }

    func requestRefresh() {
        needsAnotherPass = true
        guard runningTask == nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            try? await self.runRefresh()
        }
    }

    func refreshNow(actionMessage: String? = nil) async throws {
        debounceTask?.cancel()
        debounceTask = nil
        self.actionMessage = actionMessage
        needsAnotherPass = true
        try await runRefresh()
    }

    private func runRefresh() async throws {
        guard let persistence, TodoWidgetSnapshotFile.sharedDirectory() != nil else { return }
        if let runningTask {
            try await runningTask.value
            return
        }
        let task = Task { [self] in
            // Clear ownership before this task completes, so a caller cannot join an
            // already-finished pass after its own database save.
            defer { runningTask = nil }
            while needsAnotherPass {
                needsAnotherPass = false
                var snapshot = await readSnapshot(persistence: persistence)
                if needsAnotherPass { continue }
                snapshot.actionMessage = actionMessage
                try await writer.write(snapshot)
            }
        }
        runningTask = task
        try await task.value
    }

    private func readSnapshot(persistence: PersistenceController) async -> TodoWidgetSnapshot {
        let theme = AppThemeSettings.shared.color
        let appearance = TodoWidgetReader.Appearance(
            themeHex: theme.hex, lightAccentHex: theme.readableTint(onDarkBackground: false).hex,
            darkAccentHex: theme.readableTint(onDarkBackground: true).hex
        )
        let container = persistence.container
        let sharedStore = persistence.sharedPersistentStore
        let sharedStoreID = sharedStore.map(ObjectIdentifier.init)
        do {
            return try await TodoWidgetReader.read(
                coordinator: container.persistentStoreCoordinator,
                privateStore: persistence.privatePersistentStore, sharedStore: sharedStore,
                sort: UserDefaults.standard.string(forKey: "todoSort") ?? "手动", appearance: appearance,
                canUpdate: { id in
                    id.persistentStore.map(ObjectIdentifier.init) != sharedStoreID
                        || container.canUpdateRecord(forManagedObjectWith: id)
                }
            )
        } catch {
            return TodoWidgetSnapshot(
                status: .unavailable, generatedAt: Date(), spaceName: nil, pendingCount: 0, items: [],
                themeHex: appearance.themeHex, lightAccentHex: appearance.lightAccentHex,
                darkAccentHex: appearance.darkAccentHex
            )
        }
    }

    func complete(recordURI: String, spaceURI: String) async throws {
        let persistence = self.persistence ?? PersistenceController.shared
        configure(persistence: persistence)
        guard TodoWidgetSnapshotFile.sharedDirectory() != nil else {
            throw CompletionError.unavailable
        }
        let store = TodoStore(persistence: persistence)
        guard let space = try persistence.existingActiveSyncSpace(in: store.context),
              space.objectID.uriRepresentation().absoluteString == spaceURI,
              let url = URL(string: recordURI), url.scheme == "x-coredata",
              let objectID = persistence.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: url),
              objectID.persistentStore === space.objectID.persistentStore,
              let item = store.items.first(where: { $0.objectID == objectID }) else {
            throw CompletionError.unavailable
        }
        try store.setCompletion(item, completed: true)
        // WidgetKit reloads after perform returns; the saved result must already be in its cache.
        try await refreshNow()
    }

    enum CompletionError: LocalizedError {
        case unavailable
        var errorDescription: String? { "待办已变更，请打开应用更新后重试。" }
    }
}
