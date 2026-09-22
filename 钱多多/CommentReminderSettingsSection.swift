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
        Section {
            HStack {
                Label("本机通知", systemImage: "bell.badge")
                Spacer()
                Text(reminders.authorizationText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Label("待提醒", systemImage: "clock")
                Spacer()
                Text("\(reminders.pendingCount) 条")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if authorizationStatus == .notDetermined {
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
                }
                .disabled(isEnablingNotifications)
            }

            Picker(selection: $soundValue) {
                ForEach(CommentReminderSound.allCases) { sound in
                    Text(sound.title).tag(sound.rawValue)
                }
            } label: {
                Label("提示音", systemImage: "speaker.wave.2")
            }

            Button {
                if selectedSound == .system {
                    testNotification()
                } else {
                    selectedSound.preview()
                }
            } label: {
                Label("试听提示音", systemImage: "play.circle")
            }
            .disabled(isTestingNotification)

            Toggle(isOn: $liveActivitiesEnabled) {
                Label("灵动岛与锁屏倒计时", systemImage: "timer")
            }
            .tint(AppTheme.primary)

            Button {
                testNotification()
            } label: {
                Label(
                    isTestingNotification ? "正在准备测试通知" : "测试本机通知",
                    systemImage: "bell.badge.fill"
                )
            }
            .disabled(isTestingNotification)

            Button {
                openNotificationSettings()
            } label: {
                Label("系统通知设置", systemImage: "arrow.up.forward.app")
            }

            if let error = reminders.lastError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("评论提醒")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !reminders.diagnosticText.isEmpty {
                    Text(reminders.diagnosticText)
                }
                Text("共享同一份 iCloud 数据的设备会各自安排提醒，请在每台设备允许通知。离线或未及时同步时，提醒可能延后。声音和倒计时开关仅影响本机。")
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
