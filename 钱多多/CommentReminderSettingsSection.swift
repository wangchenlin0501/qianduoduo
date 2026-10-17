import SwiftUI
import UIKit
import UserNotifications

struct CommentReminderSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var reminders = VideoCommentNotificationManager.shared
    @AppStorage("commentReminderSound") private var soundValue = CommentReminderSound.system.rawValue
    @AppStorage("commentReminderLiveActivitiesEnabled") private var liveActivitiesEnabled = true

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isEnablingNotifications = false
    @State private var isTestingNotification = false
    @State private var showingTestAlert = false
    @State private var testAlertTitle = ""
    @State private var testAlertMessage = ""
    @State private var testOffersSettings = false

    private var selectedSound: CommentReminderSound {
        CommentReminderSound(rawValue: soundValue) ?? .system
    }

    var body: some View {
        SettingsCardSection(
            "评论提醒",
            footer: "各设备需单独开启通知，声音和倒计时仅影响本机。离线或同步延迟可能影响提醒。"
        ) {
            HStack(spacing: 12) {
                Label("本机通知", systemImage: "bell.badge")
                Spacer(minLength: 8)
                Text(reminders.authorizationText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .settingsRow()

            SettingsRowDivider()

            HStack(spacing: 12) {
                Label("待提醒", systemImage: "clock")
                Spacer(minLength: 8)
                Text("\(reminders.pendingCount) 条")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .settingsRow()

            if authorizationStatus == .notDetermined {
                SettingsRowDivider()

                Button {
                    isEnablingNotifications = true
                    Task {
                        await reminders.enableNotifications()
                        await refreshAuthorizationStatus()
                        isEnablingNotifications = false
                    }
                } label: {
                    Label(
                        isEnablingNotifications ? "正在开启通知" : "允许本机通知",
                        systemImage: "bell.and.waves.left.and.right"
                    )
                    .settingsRow()
                }
                .disabled(isEnablingNotifications)
            }

            SettingsRowDivider()

            HStack(spacing: 12) {
                Label("提示音", systemImage: "speaker.wave.2")
                Spacer(minLength: 8)
                Picker("提示音", selection: $soundValue) {
                    ForEach(CommentReminderSound.allCases) { sound in
                        Text(sound.title).tag(sound.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            .settingsRow()

            SettingsRowDivider()

            Button {
                if selectedSound == .system {
                    testNotification()
                } else {
                    selectedSound.preview()
                }
            } label: {
                Label("试听提示音", systemImage: "play.circle")
                    .settingsRow()
            }
            .disabled(isTestingNotification)

            SettingsRowDivider()

            Toggle(isOn: $liveActivitiesEnabled) {
                Label("灵动岛与锁屏倒计时", systemImage: "timer")
            }
            .tint(AppTheme.readablePrimary)
            .settingsRow()

            SettingsRowDivider()

            Button {
                testNotification()
            } label: {
                Label(
                    isTestingNotification ? "正在准备测试通知" : "测试本机通知",
                    systemImage: "bell.badge.fill"
                )
                .settingsRow()
            }
            .disabled(isTestingNotification)

            SettingsRowDivider()

            Button {
                openNotificationSettings()
            } label: {
                Label("系统通知设置", systemImage: "arrow.up.forward.app")
                    .settingsRow()
            }

            if let error = reminders.lastError, !error.isEmpty {
                SettingsRowDivider()
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .settingsRow()
            }
        }
        .task {
            await reminders.reconcileNow()
            await refreshAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await reminders.reconcileNow()
                await refreshAuthorizationStatus()
            }
        }
        .onChange(of: soundValue) { _, _ in
            Task { await reminders.reconcileNow() }
        }
        .onChange(of: liveActivitiesEnabled) { _, _ in
            Task { await reminders.reconcileNow() }
        }
        .alert(testAlertTitle, isPresented: $showingTestAlert) {
            if testOffersSettings {
                Button("前往设置") { openNotificationSettings() }
            }
            Button("好的", role: .cancel) { }
        } message: {
            Text(testAlertMessage)
        }
    }

    private func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func testNotification() {
        isTestingNotification = true
        reminders.scheduleTestNotification { result in
            Task { @MainActor in
                isTestingNotification = false
                testOffersSettings = false
                switch result {
                case .scheduled:
                    testAlertTitle = "测试通知已安排"
                    testAlertMessage = "约 3 秒后发送到这台设备，并使用当前提示音。测试只验证本机通知，不代表其他设备已安排视频提醒；声音仍受系统静音和通知设置影响。"
                case .permissionDenied:
                    testAlertTitle = "通知未开启"
                    testAlertMessage = "请在系统通知设置中允许钱多多发送通知，并开启声音、横幅和通知中心。"
                    testOffersSettings = true
                case .expired, .failed:
                    testAlertTitle = "测试通知失败"
                    testAlertMessage = "暂时无法安排测试通知，请稍后重试。"
                }
                showingTestAlert = true
                await refreshAuthorizationStatus()
            }
        }
    }
}
