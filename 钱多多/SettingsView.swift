//
//  SettingsView.swift
//  钱多多
//

import CloudKit
import CoreData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Settings Page

struct SettingsPage: View {
    @Environment(\.managedObjectContext) private var viewContext

    @State private var route: SettingsRoute?
    @State private var exportPresentation: ExportPresentation?
    @State private var showingImportPicker = false
    @State private var showingImportAlert = false
    @State private var importResultMessage = ""
    @State private var showingExportAlert = false
    @State private var exportErrorMessage = ""
    @State private var showingDemoHideConfirm = false
    @State private var sharingPresentation: CloudSharingPresentation?
    @State private var sharingRequestID: UUID?
    @State private var sharingTimeoutTask: Task<Void, Never>?
    @State private var isPreparingShare = false
    @State private var sharingPopoverAnchor = CloudSharingPopoverAnchor()
    @State private var cloudAccountText = "检查中"
    @State private var showingSyncAlert = false
    @State private var showingScreenshotCleanupConfirm = false
    @State private var showingScreenshotCleanupResult = false
    @State private var screenshotCleanupMessage = ""
    @State private var saveError: NSError?
    @State private var syncAlertMessage = ""
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false
    @ObservedObject private var syncService = CloudSyncRefreshService.shared

    /// Pull-to-refresh used to swallow failures, so a failed upload looked identical to "all synced".
    /// The latest manual or automatic result now stays visible here until the failing operation succeeds.
    private var syncStatusText: String {
        switch syncService.lastResult {
        case nil: "本次启动暂无记录"
        case .waiting?: "等待 iCloud"
        case .receivedUpdates?: "下载检查完成"
        case .failed?: "未完成"
        }
    }

    private var syncStatusIsFailure: Bool {
        if case .failed? = syncService.lastResult { return true }
        return false
    }

    private var syncSectionFooter: String? {
        guard case .failed(let message)? = syncService.lastResult else {
            return nil
        }
        return "\(message)\n在同步成功之前，请先不要删除 App 或更换手机；本机数据不受影响。"
    }

    var body: some View {
        let syncSection = SettingsCardSection(
                "共享同步",
                footer: syncSectionFooter
            ) {
                SettingsValueRow("iCloud 状态", systemImage: "icloud.fill") {
                    Text(cloudAccountText)
                        .foregroundStyle(cloudAccountText == "可用" ? AppTheme.success : .secondary)
                }

                SettingsRowDivider()

                SettingsValueRow("同步状态", systemImage: syncService.lastResult?.symbol ?? "icloud") {
                    Text(syncStatusText)
                        .foregroundStyle(syncStatusIsFailure ? AppTheme.warning : .secondary)
                }

                if let checkedAt = syncService.lastCheckedAt {
                    SettingsRowDivider()

                    SettingsValueRow("最近检查", systemImage: "clock") {
                        Text(checkedAt, format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRowDivider()

                Button {
                    openCloudSharing()
                } label: {
                    HStack(spacing: 12) {
                        Label(isPreparingShare ? "正在准备共享" : "创建或管理共享", systemImage: "person.2.badge.gearshape.fill")
                        Spacer(minLength: 8)
                        if isPreparingShare { ProgressView().controlSize(.small) }
                    }
                    .settingsRow()
                }
                .disabled(isPreparingShare || sharingPresentation != nil)
            }

        let themeSection = ThemeColorSettingsSection()

        let aiSection = AIAssistantSettingsSection()

        let dataSection = SettingsCardSection("数据管理") {
                Button {
                    exportData()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                        .settingsRow()
                }

                SettingsRowDivider()

                Button {
                    showingImportPicker = true
                } label: {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                        .settingsRow()
                }

                SettingsRowDivider()

                Button {
                    exportLogs()
                } label: {
                    Label("导出诊断日志", systemImage: "doc.text")
                        .settingsRow()
                }
            }

        let cleanupSection = SettingsCardSection(
                "截图清理"
            ) {
                Button(role: .destructive) {
                    showingScreenshotCleanupConfirm = true
                } label: {
                    Label("删除超过三个月的截图", systemImage: "trash")
                        .settingsRow()
                }
                .tint(AppTheme.danger)
            }

        let reminderSection = CommentReminderSettingsSection()

        let soundSection = PublishCelebrationSoundSettingsSection()

        let demoSection = SettingsCardSection(
                "展示模式"
            ) {
                Button {
                    if isDemoDataHidden {
                        isDemoDataHidden = false
                        notifyRecordsChanged()
                    } else {
                        showingDemoHideConfirm = true
                    }
                } label: {
                    Label(isDemoDataHidden ? "恢复显示记录" : "隐藏所有记录", systemImage: isDemoDataHidden ? "eye.fill" : "eye.slash.fill")
                        .settingsRow()
                }
            }

        let aboutSection = SettingsCardSection("关于与隐私") {
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    HStack(spacing: 12) {
                        Label("隐私政策", systemImage: "hand.raised.fill")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .settingsRow()
                }

                if let supportURL = URL(string: "https://github.com/wangchenlin0501/qianduoduo/issues") {
                    SettingsRowDivider()

                    Link(destination: supportURL) {
                        HStack(spacing: 12) {
                            Label("帮助与反馈", systemImage: "questionmark.circle")
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .settingsRow()
                    }
                }

                SettingsRowDivider()

                SettingsValueRow("版本", systemImage: "info.circle") {
                    Text(installedVersion)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

        List {
            syncSection

            SettingsCardSection("设置") {
                settingsEntry(.appearance)
                SettingsRowDivider()
                settingsEntry(.ai)
                SettingsRowDivider()
                settingsEntry(.reminders)
                SettingsRowDivider()
                settingsEntry(.data)
                SettingsRowDivider()
                settingsEntry(.about)
            }
        }
        .navigationDestination(item: $route) { route in
            List {
                switch route {
                case .appearance:
                    themeSection
                case .ai:
                    aiSection
                case .reminders:
                    reminderSection
                    soundSection
                case .data:
                    dataSection
                    cleanupSection
                    demoSection
                case .about:
                    aboutSection
                }
            }
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .softPageBackground()
            .tint(AppTheme.readablePrimary)
        }
        .navigationTitle("设置")
        .saveFailureAlert($saveError)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .softPageBackground()
        .tint(AppTheme.readablePrimary)
        .background {
            // Keep the iPad source in the page hierarchy even when List rows scroll away.
            CloudSharingPopoverSource(anchor: sharingPopoverAnchor)
                .allowsHitTesting(false)
        }
        .onAppear {
            refreshCloudAccountStatus()
        }
        .sheet(item: $exportPresentation) { presentation in
            ShareSheet(activityItems: [presentation.fileURL])
                .id(presentation.id)
        }
        .sheet(item: $sharingPresentation, onDismiss: {
            AppLogger.shared.log("系统共享界面已关闭")
        }) { presentation in
            CloudSharingView(
                share: presentation.share,
                container: presentation.container,
                popoverAnchor: sharingPopoverAnchor
            )
            .id(presentation.id)
            .onAppear { AppLogger.shared.log("系统共享界面已显示") }
        }
        .onDisappear { stopPreparingShare() }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert("导入结果", isPresented: $showingImportAlert) {
            Button("好的") { }
        } message: {
            Text(importResultMessage)
        }
        .alert("同步", isPresented: $showingSyncAlert) {
            Button("好的") { }
        } message: {
            Text(syncAlertMessage)
        }
        .alert("导出失败", isPresented: $showingExportAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(exportErrorMessage)
        }
        .alert("删除超过三个月的截图？", isPresented: $showingScreenshotCleanupConfirm) {
            Button("删除截图", role: .destructive) {
                deleteOldPublishedScreenshots()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只删除截图，记录和金额保留。删除会同步到你的其他设备和共享成员，无法撤回。")
        }
        .alert("截图清理完成", isPresented: $showingScreenshotCleanupResult) {
            Button("好的") { }
        } message: {
            Text(screenshotCleanupMessage)
        }
        .alert("隐藏所有记录？", isPresented: $showingDemoHideConfirm) {
            Button("隐藏记录") {
                isDemoDataHidden = true
                notifyRecordsChanged()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("各页面会暂时显示为空，可随时恢复。")
        }
    }

    private func settingsEntry(_ target: SettingsRoute) -> some View {
        Button {
            route = target
        } label: {
            HStack(spacing: 12) {
                Label(target.title, systemImage: target.systemImage)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .settingsRow()
        }
    }

    private func deleteOldPublishedScreenshots() {
        guard let cutoff = qddCalendar.date(byAdding: .month, value: -3, to: dayOnly(Date())) else { return }
        let request = NSFetchRequest<AdRecord>(entityName: "AdRecord")
        request.predicate = NSPredicate(format: "photoData != nil AND dueDate != nil AND dueDate < %@", cutoff as NSDate)
        let records: [AdRecord]
        do {
            records = try viewContext.fetch(request).filter { record in
                !(record.needsPayment && record.statusValue != .paid)
            }
        } catch {
            AppLogger.shared.log("截图清理读取记录失败: \(PersistenceController.describe(error))")
            screenshotCleanupMessage = "读取记录失败，请稍后重试。"
            showingScreenshotCleanupResult = true
            return
        }
        guard !records.isEmpty else {
            screenshotCleanupMessage = "没有符合条件的截图。"
            showingScreenshotCleanupResult = true
            return
        }
        records.forEach { record in
            record.photoData = nil
            record.updatedAt = Date()
        }
        if let error = viewContext.saveRollingBackOnFailure("删除超过三个月的截图") {
            saveError = error
            return
        }
        viewContext.processPendingChanges()
        notifyRecordsChanged()
        AppLogger.shared.log("手动删除了 \(records.count) 条记录的截图")
        screenshotCleanupMessage = "已删除 \(records.count) 条记录的截图，记录和金额保留。"
        showingScreenshotCleanupResult = true
    }

    private var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（\(build)）"
    }

    private func openCloudSharing() {
        guard !isPreparingShare, sharingPresentation == nil else { return }
        let requestID = UUID()
        sharingRequestID = requestID
        isPreparingShare = true

        CloudSharingPreparationService.shared.prepare(requestID: requestID) { result in
            guard sharingRequestID == requestID else { return }
            stopPreparingShare()
            switch result {
            case .success(let presentation):
                sharingPresentation = presentation
            case .failure(let error):
                syncAlertMessage = "准备共享失败：\(error.localizedDescription)"
                showingSyncAlert = true
            }
        }
        // Configuration failures may complete synchronously and already clear this request.
        guard sharingRequestID == requestID else { return }
        sharingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch { return }
            guard sharingRequestID == requestID else { return }
            stopPreparingShare()
            syncAlertMessage = "iCloud 响应较慢，已停止等待。你可以继续使用其他功能，稍后再试。"
            showingSyncAlert = true
            AppLogger.shared.log("共享界面等待超时，后台任务保留，重试时复用同一任务")
        }
    }

    private func stopPreparingShare() {
        sharingTimeoutTask?.cancel()
        sharingTimeoutTask = nil
        if let sharingRequestID {
            CloudSharingPreparationService.shared.stopWaiting(requestID: sharingRequestID)
        }
        sharingRequestID = nil
        isPreparingShare = false
    }

    private func refreshCloudAccountStatus() {
        cloudAccountText = "检查中"
        PersistenceController.shared.cloudAccountStatus { status, error in
            DispatchQueue.main.async {
                if error != nil {
                    cloudAccountText = "无法确认"
                    return
                }

                switch status {
                case .available:
                    cloudAccountText = "可用"
                case .noAccount:
                    cloudAccountText = "未登录"
                case .restricted:
                    cloudAccountText = "受限制"
                case .temporarilyUnavailable:
                    cloudAccountText = "暂不可用"
                case .couldNotDetermine:
                    cloudAccountText = "无法确认"
                @unknown default:
                    cloudAccountText = "未知"
                }
            }
        }
    }

    private func exportData() {
        guard let jsonData = exportRecords(context: viewContext) else {
            exportErrorMessage = "暂时无法导出数据，请稍后重试。"
            showingExportAlert = true
            return
        }
        presentExport(data: jsonData, fileName: "钱多多_备份_\(shortExportDate()).json")
    }

    private func exportLogs() {
        let logs = AppLogger.shared.logs
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let text = [
            "钱多多运行日志",
            "版本：\(version)（\(build)）",
            "系统：iOS \(UIDevice.current.systemVersion)",
            "导出时间：\(shortExportDate())",
            "当前会话：\(AppLogger.shared.sessionDescription)",
            "正文保留历史日志，请结合当前会话开始时间判断本次错误。",
            "",
            logs.isEmpty ? "暂无运行日志。" : logs.joined(separator: "\n")
        ].joined(separator: "\n")
        presentExport(data: Data(text.utf8), fileName: "钱多多_日志_\(shortExportDate()).txt")
    }

    private func presentExport(data: Data, fileName: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: tempURL, options: .atomic)
            // Present from the prepared file itself so the first sheet never captures a nil URL.
            exportPresentation = ExportPresentation(fileURL: tempURL)
        } catch {
            exportErrorMessage = "文件导出失败，请重试。\(error.localizedDescription)"
            showingExportAlert = true
            AppLogger.shared.log("写入导出文件失败: \(error.localizedDescription)")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                importResultMessage = "无法访问文件"
                showingImportAlert = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let summary = try importRecords(data: data, context: viewContext)
                AIBackup.restore(from: data, in: viewContext)
                importResultMessage = summary.message
            } catch BackupImportError.unsavedDataSpace {
                // Not a damaged file: an editor still holds new content, so do not blame the backup.
                importResultMessage = BackupImportError.unsavedDataSpace.localizedDescription
            } catch {
                importResultMessage = "导入失败，请检查备份文件是否完整。\n\(error.localizedDescription)"
            }
            showingImportAlert = true
        case .failure(let error):
            importResultMessage = "选择文件失败: \(error.localizedDescription)"
            showingImportAlert = true
        }
    }

    private func shortExportDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.timeZone = qddTimeZone
        return df.string(from: Date())
    }
}

private struct ExportPresentation: Identifiable {
    let id = UUID()
    let fileURL: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum SettingsRoute: Hashable {
    case appearance, ai, reminders, data, about

    var title: String {
        switch self {
        case .appearance: "外观"
        case .ai: "AI 助手"
        case .reminders: "提醒与音效"
        case .data: "数据管理"
        case .about: "关于与隐私"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .ai: "sparkles"
        case .reminders: "bell.fill"
        case .data: "externaldrive.fill"
        case .about: "hand.raised.fill"
        }
    }
}
