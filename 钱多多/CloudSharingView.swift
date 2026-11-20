import CloudKit
import SwiftUI
import UIKit

/// Keep the source in Settings alive while the system opens its invitation and activity screens.
@MainActor
final class CloudSharingPopoverAnchor {
    let sourceView = SourceView()
    private weak var popover: UIPopoverPresentationController?

    init() {
        sourceView.anchor = self
        sourceView.isUserInteractionEnabled = false
        sourceView.accessibilityElementsHidden = true
        sourceView.backgroundColor = .clear
    }

    func configure(_ controller: UIViewController) {
        controller.modalPresentationStyle = .popover
        popover = controller.popoverPresentationController
        popover?.sourceView = sourceView
        popover?.permittedArrowDirections = []
        updateSourceRect()
    }

    fileprivate func updateSourceRect() {
        // A background view gets its final page bounds after makeUIViewController.
        // Update for layout/rotation, and never leave an empty iPad popover source rect.
        let bounds = sourceView.bounds
        popover?.sourceRect = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
    }

    final class SourceView: UIView {
        fileprivate weak var anchor: CloudSharingPopoverAnchor?

        override func layoutSubviews() {
            super.layoutSubviews()
            anchor?.updateSourceRect()
        }
    }
}

struct CloudSharingPopoverSource: UIViewRepresentable {
    let anchor: CloudSharingPopoverAnchor

    func makeUIView(context: Context) -> UIView { anchor.sourceView }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let popoverAnchor: CloudSharingPopoverAnchor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        AppLogger.shared.log("创建系统共享界面；链接已就绪：\(share.url == nil ? "否" : "是")，参与者：\(share.participants.count)")
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        popoverAnchor.configure(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        popoverAnchor.updateSourceRect()
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            AppLogger.shared.log("系统共享界面保存失败: \(PersistenceController.describe(error))")
            PersistenceController.shared.pauseSharingIfConfigurationError(error)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { "钱多多共享数据" }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            // Since iOS 16.4 Core Data automatically observes the system sharing UI.
            // Our minimum is iOS 18.6: do not reenter persistUpdatedShare in its save callback.
            // https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users
            AppLogger.shared.log("系统共享界面已保存邀请；Core Data 自动更新共享元数据，其他设备接收仍需等待同步")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            AppLogger.shared.log("系统共享界面已停止共享；Core Data 自动更新共享元数据")
        }
    }
}
