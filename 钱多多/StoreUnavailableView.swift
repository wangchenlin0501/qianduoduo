//
//  StoreUnavailableView.swift
//  钱多多
//

import SwiftUI

/// Shown instead of the app when the local database cannot be opened.
/// Crashing at launch would give the user no explanation and no way to send diagnostics.
/// There is deliberately no retry button: a store that failed is not loaded a second time in the
/// same process, and nothing here recreates or deletes database files.
struct StoreUnavailableView: View {
    let details: String
    @ObservedObject private var logger = AppLogger.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityHidden(true)

                Text("暂时无法打开数据")
                    .font(.title2.weight(.bold))

                Text("App 没有删除任何数据。请先从多任务界面彻底关闭钱多多再重新打开；如果仍然这样，请检查 iPhone 的存储空间是否已满，并尝试重启手机。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ShareLink(item: diagnosticsText) {
                    Label("导出诊断日志", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Text(details)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The error itself goes first: the log may already have rotated past the failure entry.
    private var diagnosticsText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return [
            "钱多多数据库打开失败诊断",
            "版本：\(version)（\(build)）",
            "当前会话：\(logger.sessionDescription)",
            "错误：\(details)",
            "",
            logger.logs.isEmpty ? "暂无运行日志。" : logger.logs.joined(separator: "\n")
        ].joined(separator: "\n")
    }
}

/// Only visible if the stores ever finish opening after launch; loading is synchronous today.
struct StoreLoadingView: View {
    var body: some View {
        ProgressView("正在打开数据…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    StoreUnavailableView(details: "NSCocoaErrorDomain 134060（示例）")
}
