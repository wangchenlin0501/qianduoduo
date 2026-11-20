//
//  QianDuoDuoApp.swift
//  钱多多
//
//  Created by Mashiro on 2026/5/7.
//

import CloudKit
import CoreData
import SwiftUI
import UIKit
import UserNotifications

final class SharingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            PersistenceController.shared.acceptShare(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PersistenceController.shared.acceptShare(cloudKitShareMetadata)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let persistence = PersistenceController.shared
        // Reconciling reminders against a missing or half-opened store would cancel valid notifications.
        if persistence.loadState.isReady {
            VideoCommentNotificationManager.shared.configure(container: persistence.container)
        } else {
            AppLogger.shared.log("数据库未就绪，本次启动不同步评论提醒")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SharingSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PersistenceController.shared.acceptShare(cloudKitShareMetadata)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
        Task { @MainActor in
            VideoCommentNotificationManager.shared.recordForegroundDelivery(notification)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await VideoCommentNotificationManager.shared.handleResponse(response)
            completionHandler()
        }
    }
}

@main
struct QianDuoDuoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @ObservedObject private var persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            // Data screens fetch and save immediately, so they appear only once every store is open.
            switch persistenceController.loadState {
            case .ready:
                ContentView()
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .environment(\.calendar, qddCalendar)
                    .environment(\.timeZone, qddTimeZone)
            case .loading:
                StoreLoadingView()
            case .failed(let error):
                StoreUnavailableView(details: PersistenceController.describe(error))
            }
        }
    }
}
