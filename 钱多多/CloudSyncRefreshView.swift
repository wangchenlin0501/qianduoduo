import SwiftUI

private struct CloudSyncRefreshModifier: ViewModifier {
    @State private var failureMessage: String?

    func body(content: Content) -> some View {
        content
            .refreshable {
                // The service owns the task, so leaving this page does not cancel the refresh.
                // SwiftUI supplies the pull-to-refresh spinner. A failure is shown to the user,
                // because "nothing happened" looks exactly like "everything is synced".
                let result = await CloudSyncRefreshService.shared.refresh()
                if case .failed(let message) = result {
                    failureMessage = message
                }
            }
            .alert("iCloud 同步未完成", isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )) {
                Button("好的", role: .cancel) { failureMessage = nil }
            } message: {
                Text("\(failureMessage ?? "")\n\n在同步成功之前，请先不要删除 App 或更换手机；本机数据不受影响。")
            }
    }
}

extension View {
    func cloudSyncRefreshable() -> some View {
        modifier(CloudSyncRefreshModifier())
    }
}
