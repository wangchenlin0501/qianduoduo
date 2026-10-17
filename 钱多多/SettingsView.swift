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

    @State private var showingExportShare = false
    @State private var exportFileURL: URL?
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
    @State private var cloudAccountText = "检查中"
    @State private var showingSyncAlert = false
    @State private var syncAlertMessage = ""
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    var body: some View {
        List {
            SettingsCardSection(
                "共享同步",
                footer: "创建共享并通过 Apple ID 邀请成员。对方接受后，可共同管理池子、视频、账本和粉丝数据。"
            ) {
                HStack(spacing: 12) {
                    Label("iCloud 状态", systemImage: "icloud.fill")
                    Spacer(minLength: 8)
                    Text(cloudAccountText)
                        .foregroundStyle(cloudAccountText == "可用" ? .green : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                .settingsRow()

                SettingsRowDivider()

                Button {
                    openCloudSharing()
                } label: {
                    HStack(spacing: 12) {
                        Label(isPreparingShare ? "正在准备共享" : "创建/管理共享", systemImage: "person.2.badge.gearshape.fill")
                        Spacer(minLength: 8)
                        if isPreparingShare { ProgressView().controlSize(.small) }
                    }
                    .settingsRow()
                }
                .disabled(isPreparingShare)
            }

            ThemeColorSettingsSection()

            SettingsCardSection("数据管理") {
                Button {
                    exportData()
                } label: {
                    Label("导出数据", systemImage: "square.and.arrow.up")
                        .settingsRow()
                }

                SettingsRowDivider()

                Button {
                    showingImportPicker = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                        .settingsRow()
                }
            }

            CommentReminderSettingsSection()

            PublishCelebrationSoundSettingsSection()

            SettingsCardSection(
                "演示模式",
                footer: "临时隐藏所有记录，用来给他人展示空白软件；数据不会删除，随时可以恢复显示。"
            ) {
                Button {
                    if isDemoDataHidden {
                        isDemoDataHidden = false
                        notifyRecordsChanged()
                    } else {
                        showingDemoHideConfirm = true
                    }
                } label: {
                    Label(isDemoDataHidden ? "恢复显示所有数据" : "一键清空展示数据", systemImage: isDemoDataHidden ? "eye.fill" : "eye.slash.fill")
                        .settingsRow()
                }
                .foregroundStyle(isDemoDataHidden ? AppTheme.readablePrimary : Color.red)
            }

            SettingsCardSection("日志") {
                Button {
                    exportLogs()
                } label: {
                    Label("导出日志", systemImage: "doc.text")
                        .settingsRow()
                }
            }
        }
        .navigationTitle("设置")
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .softPageBackground()
        .tint(AppTheme.readablePrimary)
        .onAppear {
            refreshCloudAccountStatus()
        }
        .sheet(isPresented: $showingExportShare) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(item: $sharingPresentation) { presentation in
            CloudSharingView(
                syncSpaceID: presentation.syncSpaceID,
                share: presentation.share,
                container: presentation.container
            )
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
        .alert("一键清空展示数据", isPresented: $showingDemoHideConfirm) {
            Button("临时隐藏", role: .destructive) {
                isDemoDataHidden = true
                notifyRecordsChanged()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这不会删除任何记录，只是让汇总、池子、视频和账本暂时显示为空。")
        }
    }

    private func openCloudSharing() {
        guard !isPreparingShare else { return }
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
            "",
            logs.isEmpty ? "暂无运行日志。" : logs.joined(separator: "\n")
        ].joined(separator: "\n")
        presentExport(data: Data(text.utf8), fileName: "钱多多_日志_\(shortExportDate()).txt")
    }

    private func presentExport(data: Data, fileName: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: tempURL, options: .atomic)
            exportFileURL = tempURL
            showingExportShare = true
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
                importResultMessage = summary.message
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

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CloudSharingView: UIViewControllerRepresentable {
    let syncSpaceID: NSManagedObjectID
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator {
        Coordinator(syncSpaceID: syncSpaceID)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let syncSpaceID: NSManagedObjectID

        init(syncSpaceID: NSManagedObjectID) {
            self.syncSpaceID = syncSpaceID
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            AppLogger.shared.log("保存共享失败: \(PersistenceController.describe(error))")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "钱多多共享数据"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            if let share = csc.share {
                PersistenceController.shared.persistUpdatedShare(share, for: syncSpaceID)
            }
            AppLogger.shared.log("共享邀请已保存")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            AppLogger.shared.log("已停止共享")
        }
    }
}
