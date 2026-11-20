import AppIntents
import Foundation
import WidgetKit

struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "完成待办"
    static let description = IntentDescription("将当前数据空间中的待办标记为已完成。")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "待办标识") var recordURI: String
    @Parameter(title: "数据空间") var spaceURI: String

    init() {}
    init(recordURI: String, spaceURI: String) {
        self.recordURI = recordURI
        self.spaceURI = spaceURI
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if QDD_WIDGET_EXTENSION
        // Older systems should dispatch the app-only foreground-continuable conformance.
        // If dispatch fails, leave the checkbox unchanged and display a truthful failure.
        if let directory = TodoWidgetSnapshotFile.sharedDirectory() {
            var snapshot = TodoWidgetSnapshotFile.read() ?? .unavailable
            snapshot.actionMessage = "暂时无法完成，请打开应用后重试"
            try? TodoWidgetSnapshotFile.write(snapshot, to: directory)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TodoWidgetSnapshot.kind)
        #else
        let bridge = TodoWidgetBridge.shared
        bridge.configure(persistence: .shared)
        do {
            try await bridge.complete(recordURI: recordURI, spaceURI: spaceURI)
        } catch {
            try? await bridge.refreshNow(actionMessage: "未能完成，请打开应用检查共享权限后重试")
        }
        #endif
        return .result()
    }
}
