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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var logger = AppLogger.shared

    @State private var showingExportShare = false
    @State private var exportFileURL: URL?
    @State private var showingImportPicker = false
    @State private var showingImportAlert = false
    @State private var importResultMessage = ""
    @State private var showingClearConfirm = false
    @State private var showingDemoHideConfirm = false
    @State private var showingCloudShare = false
    @State private var sharingSyncSpace: SyncSpace?
    @State private var sharingShare: CKShare?
    @State private var sharingContainer: CKContainer?
    @State private var isPreparingShare = false
    @State private var cloudAccountText = "检查中"
    @State private var showingSyncAlert = false
    @State private var syncAlertMessage = ""
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    var body: some View {
        List {
            Section(
                header: Text("共享同步"),
                footer: Text("数据所有者创建共享并邀请协作者；接受邀请后，设备可同步同一份池子、视频、账本和粉丝数据。")
            ) {
                HStack {
                    Label("iCloud 状态", systemImage: "icloud.fill")
                    Spacer()
                    Text(cloudAccountText)
                        .foregroundStyle(cloudAccountText == "可用" ? .green : .secondary)
                }

                Button {
                    openCloudSharing()
                } label: {
                    Label(isPreparingShare ? "正在准备共享" : "创建/管理共享", systemImage: "person.2.badge.gearshape.fill")
                }
                .disabled(isPreparingShare)
            }

            Section(header: Text("数据管理")) {
                Button {
                    exportData()
                } label: {
                    Label("导出数据", systemImage: "square.and.arrow.up")
                }

                Button {
                    showingImportPicker = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                }
            }

            CommentReminderSettingsSection()

            Section(
                header: Text("演示模式"),
                footer: Text("临时隐藏所有记录，用来给他人展示空白软件；数据不会删除，随时可以恢复显示。")
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
                }
                .foregroundStyle(isDemoDataHidden ? AppTheme.primary : Color.red)
            }

            Section(header: Text("日志"), footer: Text("只保留最近 80 条运行日志，便于排查同步或其他问题")) {
                if logger.logs.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logger.logs.reversed(), id: \.self) { log in
                        Text(log)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("清除日志", systemImage: "trash")
                }
            }
        }
        .navigationTitle("设置")
        .listStyle(.insetGrouped)
        .softPageBackground()
        .onAppear {
            refreshCloudAccountStatus()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showingExportShare) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showingCloudShare, onDismiss: resetSharingPresentation) {
            if let sharingSyncSpace, let sharingShare, let sharingContainer {
                CloudSharingView(
                    syncSpace: sharingSyncSpace,
                    share: sharingShare,
                    container: sharingContainer
                )
            }
        }
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
        .alert("确认清除", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) {
                logger.clearLogs()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要清除所有日志吗？")
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
        do {
            let syncSpace = try PersistenceController.shared.prepareSharingSpace(in: viewContext)
            isPreparingShare = true

            if let existingShare = PersistenceController.shared.existingShare(for: syncSpace) {
                PersistenceController.shared.shareExistingRecordsIfNeeded(for: syncSpace, share: existingShare)
                presentCloudSharing(
                    syncSpace: syncSpace,
                    share: existingShare,
                    container: CKContainer(identifier: PersistenceController.cloudKitContainerIdentifier)
                )
                return
            }

            PersistenceController.shared.share(syncSpace: syncSpace) { share, container, error in
                DispatchQueue.main.async {
                    isPreparingShare = false

                    if let error {
                        syncAlertMessage = "创建共享失败：\(PersistenceController.describe(error))"
                        showingSyncAlert = true
                        AppLogger.shared.log(syncAlertMessage)
                        return
                    }

                    guard let share, let container else {
                        syncAlertMessage = "创建共享失败：系统没有返回共享信息，请确认已登录 iCloud 后再试。"
                        showingSyncAlert = true
                        AppLogger.shared.log(syncAlertMessage)
                        return
                    }

                    presentCloudSharing(syncSpace: syncSpace, share: share, container: container)
                }
            }
        } catch {
            isPreparingShare = false
            syncAlertMessage = "准备共享失败：\(PersistenceController.describe(error))"
            showingSyncAlert = true
            AppLogger.shared.log(syncAlertMessage)
        }
    }

    private func presentCloudSharing(syncSpace: SyncSpace, share: CKShare, container: CKContainer) {
        sharingSyncSpace = syncSpace
        sharingShare = share
        sharingContainer = container
        isPreparingShare = false
        showingCloudShare = true
    }

    private func resetSharingPresentation() {
        sharingSyncSpace = nil
        sharingShare = nil
        sharingContainer = nil
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
        guard let jsonData = exportRecords(context: viewContext) else { return }
        let fileName = "钱多多_备份_\(shortExportDate()).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try jsonData.write(to: tempURL)
            exportFileURL = tempURL
            showingExportShare = true
        } catch {
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
                let count = importRecords(data: data, context: viewContext)
                importResultMessage = count > 0 ? "成功导入 \(count) 条记录" : "导入失败，请检查文件格式"
            } catch {
                importResultMessage = "读取文件失败: \(error.localizedDescription)"
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
    @ObservedObject var syncSpace: SyncSpace
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator {
        Coordinator(syncSpace: syncSpace)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let syncSpace: SyncSpace

        init(syncSpace: SyncSpace) {
            self.syncSpace = syncSpace
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            AppLogger.shared.log("保存共享失败: \(PersistenceController.describe(error))")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "钱多多共享数据"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            if let share = csc.share {
                PersistenceController.shared.persistUpdatedShare(share, for: syncSpace)
            }
            AppLogger.shared.log("共享邀请已保存")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            AppLogger.shared.log("已停止共享")
        }
    }
}
