import Combine
import CoreData
import Foundation
import UIKit
import UserNotifications

enum VideoCommentReminderResult {
    case scheduled, permissionDenied, expired, failed
}

struct CommentReminderLink: Identifiable {
    let id: String
}

@MainActor
final class VideoCommentNotificationManager: ObservableObject {
    static let shared = VideoCommentNotificationManager()
    static let categoryID = "video-brand-comment"
    static let completeActionID = "video-brand-comment-complete"
    private static let prefix = "video-comment-v2-"
    private static let testID = "video-comment-notification-test"

    @Published private(set) var authorizationText = "检查中"
    @Published private(set) var pendingCount = 0
    @Published private(set) var diagnosticText = "每台设备需开启通知，并同步同一份数据。"
    @Published private(set) var lastError: String?
    @Published private(set) var statuses: [String: String] = [:]
    @Published var openedReminder: CommentReminderLink?

    private let center = UNUserNotificationCenter.current()
    private var container: NSPersistentCloudKitContainer?
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var runningTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private let ledgerKey = "commentReminderScheduledDates.v2"
    private var scheduledDates: [String: Double]
    private var dueRefreshTask: Task<Void, Never>?

    private init() {
        scheduledDates = UserDefaults.standard.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:]
    }

    func configure(container: NSPersistentCloudKitContainer) {
        guard self.container == nil else { return }
        self.container = container
        let complete = UNNotificationAction(identifier: Self.completeActionID, title: "已评论", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [complete], intentIdentifiers: [])
        ])
        for name in [Notification.Name.NSPersistentStoreRemoteChange, .NSManagedObjectContextDidSave, .adRecordsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestReconciliation() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil, event.succeeded else { return }
            Task { @MainActor [weak self] in self?.requestReconciliation() }
        })
        requestReconciliation()
    }

    func requestReconciliation() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reconcileNow()
        }
    }

    func reconcileNow() async {
        needsAnotherPass = true
        if let runningTask {
            await runningTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "同步评论提醒")
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
            while self.needsAnotherPass {
                self.needsAnotherPass = false
                await self.reconcilePass()
            }
        }
        runningTask = task
        await task.value
        runningTask = nil
        if needsAnotherPass { await reconcileNow() }
    }

    func enableNotifications() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { lastError = "申请通知权限失败：\(error.localizedDescription)" }
        } else if settings.authorizationStatus == .denied,
                  let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            await UIApplication.shared.open(url)
        }
        await reconcileNow()
    }

    /// Also called on foreground activation, so every sharing device can opt in.
    func publicationDidSave() async {
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            await enableNotifications()
        } else {
            await reconcileNow()
        }
    }

    private func freshContext() -> NSManagedObjectContext? {
        guard let container, !container.persistentStoreCoordinator.persistentStores.isEmpty else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = container.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        return context
    }

    private func reconcilePass() async {
        let settings = await center.notificationSettings()
        let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        switch settings.authorizationStatus {
        case .authorized: authorizationText = "已允许"
        case .provisional: authorizationText = "静默通知"
        case .ephemeral: authorizationText = "临时允许"
        case .notDetermined: authorizationText = "尚未开启"
        case .denied: authorizationText = "未允许"
        @unknown default: authorizationText = "无法确认"
        }
        var hints: [String] = []
        if !allowed { hints.append("请在这台设备上开启通知，随后会自动检查并补排提醒。") }
        else {
            if settings.alertSetting != .enabled { hints.append("横幅提醒未开启") }
            if settings.soundSetting != .enabled { hints.append("通知声音未开启") }
            if settings.notificationCenterSetting != .enabled { hints.append("通知中心未开启") }
            if settings.scheduledDeliverySetting == .enabled { hints.append("系统已启用定时摘要，可能延后显示") }
        }
        diagnosticText = hints.isEmpty ? "本机已开启提醒；其他设备需各自允许通知并及时同步。" : hints.joined(separator: "；")
        guard let context = freshContext() else { return }
        let events: [CommentReminderEvent]
        do { events = CommentReminderStore.events(from: try CommentReminderStore.records(in: context)) }
        catch {
            lastError = "读取提醒失败：\(error.localizedDescription)"
            return // Never clear valid requests when the store could not be read.
        }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let now = Date()
        let validIDs = Set(events.filter { $0.completedAt == nil }.map(\.id))
        // Never remove delivered notifications simply because video metadata changed.
        let obsolete = pending.filter { request in
            if request.identifier.hasPrefix(Self.prefix) {
                return !validIDs.contains(String(request.identifier.dropFirst(Self.prefix.count)))
            }
            guard request.identifier.hasPrefix("video-comment-"), request.identifier != Self.testID else { return false }
            // Retire old-format reminders for videos that were deleted or unpublished.
            return !events.contains { matches(request, event: $0) }
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)

        var nextStatuses: [String: String] = [:]
        var queued = 0
        var passError: String?
        for event in events {
            let id = Self.prefix + event.id
            let oldPending = pending.first { matches($0, event: event) }
            let oldDelivered = delivered.first { matches($0.request, event: event) }
            let lastScheduledDate = scheduledDates[event.id].map(Date.init(timeIntervalSince1970:))
            let plan = CommentReminderPlan.decide(event: event, now: now, hasPending: oldPending != nil,
                                                 hasDelivered: oldDelivered != nil, lastScheduledDate: lastScheduledDate)
            if event.completedAt != nil {
                nextStatuses[event.id] = "已评论品牌名"
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { matches($0.request, event: event) }.map { $0.request.identifier })
                if let oldPending { center.removePendingNotificationRequests(withIdentifiers: [oldPending.identifier]) }
                continue
            }
            guard allowed else {
                nextStatuses[event.id] = "本机通知未开启"
                continue
            }
            var targetDate: Date?
            switch plan {
            case .schedule(let date): targetDate = date
            case .keepPending:
                // The accepted absolute deadline is authoritative; inspecting a
                // relative trigger must never restart the countdown on a sync.
                let due = lastScheduledDate ?? event.fireDate
                scheduledDates[event.id] = due.timeIntervalSince1970
                // Replace in place only when content/sound changed, retaining the due time.
                let soundName = CommentReminderSound.selected.rawValue
                if oldPending?.identifier != id
                    || oldPending?.content.userInfo["videoName"] as? String != event.videoName
                    || oldPending?.content.userInfo["sound"] as? String != soundName {
                    targetDate = max(due, now.addingTimeInterval(1))
                } else {
                    queued += 1
                    nextStatuses[event.id] = "本机将于 \(timeText(due)) 提醒"
                }
            case .alreadyHandled:
                nextStatuses[event.id] = oldDelivered == nil ? "已到提醒时间 · 待评论" : "通知中心有提醒 · 待评论"
                if let oldDelivered { scheduledDates[event.id] = oldDelivered.date.timeIntervalSince1970 }
            case .tooOld: nextStatuses[event.id] = "已过提醒时间 · 待评论"
            case .completed: break
            }
            guard let targetDate else { continue }
            guard queued < 60 else {
                nextStatuses[event.id] = "等待安排提醒"
                continue
            }
            do {
                try await center.add(makeRequest(event: event, date: targetDate, catchUp: event.fireDate < now))
                if let oldPending, oldPending.identifier != id {
                    center.removePendingNotificationRequests(withIdentifiers: [oldPending.identifier])
                }
                scheduledDates[event.id] = targetDate.timeIntervalSince1970
                UserDefaults.standard.set(scheduledDates, forKey: ledgerKey)
                queued += 1
                nextStatuses[event.id] = "本机将于 \(timeText(targetDate)) 提醒"
                AppLogger.shared.log("评论提醒已安排：\(timeText(targetDate))")
            } catch {
                passError = "“\(event.videoName)”提醒安排失败：\(error.localizedDescription)"
                nextStatuses[event.id] = "提醒安排失败 · 点击重试"
                AppLogger.shared.log(passError!)
            }
        }
        scheduledDates = scheduledDates.filter { $0.value > now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970 }
        UserDefaults.standard.set(scheduledDates, forKey: ledgerKey)
        pendingCount = (await center.pendingNotificationRequests()).filter { $0.identifier.hasPrefix("video-comment-") && $0.identifier != Self.testID }.count
        statuses = nextStatuses
        let activityInfos = events.filter { $0.completedAt == nil && now.timeIntervalSince($0.fireDate) < 3_600 }.map {
            CommentReminderActivityInfo(id: $0.id, videoName: $0.videoName, publishedAt: $0.publishedAt, fireDate: $0.fireDate)
        }
        await CommentReminderLiveActivityManager.shared.reconcile(reminders: activityInfos)
        lastError = passError ?? CommentReminderLiveActivityManager.shared.lastError
        dueRefreshTask?.cancel()
        if let nextDate = events.filter({ $0.completedAt == nil }).map(\.fireDate).filter({ $0 > now }).min() {
            dueRefreshTask = Task { [weak self] in
                // UI refresh only. iOS owns the actual notification and countdown.
                try? await Task.sleep(for: .seconds(max(nextDate.timeIntervalSinceNow + 1, 1)))
                guard !Task.isCancelled else { return }
                self?.requestReconciliation()
            }
        }
    }

    private func matches(_ request: UNNotificationRequest, event: CommentReminderEvent) -> Bool {
        if request.identifier == Self.prefix + event.id { return true }
        guard request.identifier.hasPrefix("video-comment-"), request.identifier != Self.testID,
              request.content.userInfo["reminderID"] == nil,
              request.content.userInfo["videoName"] as? String == event.videoName,
              let published = request.content.userInfo["publishedDate"] as? Double,
              abs(published - event.publishedAt.timeIntervalSinceReferenceDate) < 0.01 else { return false }
        let oldDate = (request.content.userInfo["videoDate"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
        return oldDate.map(dayOnly) == event.videoDate.map(dayOnly)
    }

    private func body(for event: CommentReminderEvent, catchUp: Bool) -> String {
        catchUp ? "“\(event.videoName)”已到评论时间，记得评论品牌名" : "“\(event.videoName)”发布2小时55分钟了，记得评论品牌名"
    }

    private func makeRequest(event: CommentReminderEvent, date: Date, catchUp: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "评论提醒"
        content.body = body(for: event, catchUp: catchUp)
        content.sound = CommentReminderSound.selected.notificationSound
        content.threadIdentifier = "video-comment-reminders"
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reminderID": event.id, "videoName": event.videoName,
                            "publishedDate": event.publishedAt.timeIntervalSinceReferenceDate,
                            "sound": CommentReminderSound.selected.rawValue]
        return UNNotificationRequest(identifier: Self.prefix + event.id, content: content,
                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(date.timeIntervalSinceNow, 1), repeats: false))
    }

    @discardableResult
    func markCompleted(id: String) async -> Bool {
        guard let context = freshContext() else { lastError = "数据正在加载，请稍后再试。"; return false }
        do {
            let records = try CommentReminderStore.records(in: context).filter { CommentReminderStore.eventID(for: $0) == id }
            guard !records.isEmpty else { lastError = "尚未同步到这条视频，请稍后重试。"; return false }
            let completedAt = records.compactMap(\.brandCommentedAt).max() ?? Date()
            for record in records {
                record.brandCommentedAt = completedAt
                record.updatedAt = Date()
            }
            try context.save()
            PersistenceController.shared.shareOwnedRecordsIfNeeded(records)
            notifyRecordsChanged()
            await reconcileNow()
            return true
        } catch {
            lastError = "保存已评论状态失败：\(error.localizedDescription)"
            AppLogger.shared.log(lastError!)
            return false
        }
    }

    func handleResponse(_ response: UNNotificationResponse) async {
        var id = response.notification.request.content.userInfo["reminderID"] as? String
        if id == nil, let context = freshContext(), let records = try? CommentReminderStore.records(in: context) {
            id = CommentReminderStore.events(from: records).first { matches(response.notification.request, event: $0) }?.id
        }
        guard let id else { return }
        if response.actionIdentifier == Self.completeActionID { await markCompleted(id: id) }
        else if response.actionIdentifier == UNNotificationDefaultActionIdentifier { openedReminder = CommentReminderLink(id: id) }
    }

    func recordForegroundDelivery(_ notification: UNNotification) {
        if let id = notification.request.content.userInfo["reminderID"] as? String {
            scheduledDates[id] = notification.date.timeIntervalSince1970
            UserDefaults.standard.set(scheduledDates, forKey: ledgerKey)
            statuses[id] = "提醒已触发 · 待评论"
        }
        requestReconciliation()
    }

    func open(_ url: URL) {
        guard url.scheme == "qianduoduo", url.host == "comment-reminder",
              let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return }
        openedReminder = CommentReminderLink(id: id)
    }

    func scheduleTestNotification(completion: @escaping (VideoCommentReminderResult) -> Void) {
        Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined { await enableNotifications() }
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
                completion(.permissionDenied); return
            }
            let content = UNMutableNotificationContent()
            content.title = "通知测试"
            content.body = "这是本机测试通知，用来确认当前的横幅和提示音设置。"
            content.sound = CommentReminderSound.selected.notificationSound
            content.interruptionLevel = .timeSensitive
            do {
                try await center.add(UNNotificationRequest(identifier: Self.testID, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
                completion(.scheduled)
            } catch {
                lastError = "测试通知安排失败：\(error.localizedDescription)"
                completion(.failed)
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = qddTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
