import CoreData
import SwiftUI
import UIKit

/// A native drag source confined to the pending row's badge, never the List row.
struct PendingVideoCalendarDragBadge: UIViewRepresentable {
    @Environment(\.appThemeColor) private var appThemeColor
    let group: VideoGroup
    let dragScope: UUID

    func makeUIView(context: Context) -> PendingVideoDragBadgeView {
        let view = PendingVideoDragBadgeView()
        view.configure(group: group, dragScope: dragScope)
        return view
    }

    func updateUIView(_ view: PendingVideoDragBadgeView, context: Context) {
        _ = appThemeColor
        view.configure(group: group, dragScope: dragScope)
    }
}

final class PendingVideoDragBadgeView: UIView, UIDragInteractionDelegate {
    private var badgeContent: (UIView & UIContentView)?
    private let previewContent = VideoCalendarTileArtwork()
    private var source: VideoCalendarDragSource?
    private var dragInteraction: UIDragInteraction?

    func configure(group: VideoGroup, dragScope: UUID) {
        source = group.records.first.map {
            VideoCalendarDragSource(scopeID: dragScope, recordURI: $0.objectID.uriRepresentation().absoluteString)
        }
        let badgeConfiguration = UIHostingConfiguration { DateSquare(date: nil) }.margins(.all, 0)
        if let badgeContent {
            badgeContent.configuration = badgeConfiguration
        } else {
            let content = badgeConfiguration.makeContentView()
            content.isUserInteractionEnabled = false
            addSubview(content)
            badgeContent = content
        }
        previewContent.configure(title: group.title, isPublished: group.allPublished)
        previewContent.frame = CGRect(x: 0, y: 0, width: 46, height: 46)
        previewContent.layoutIfNeeded()

        if dragInteraction == nil {
            let interaction = UIDragInteraction(delegate: self)
            interaction.isEnabled = true
            addInteraction(interaction)
            dragInteraction = interaction
        }
        isAccessibilityElement = true
        accessibilityLabel = "\(group.title)，未选发布时间"
        accessibilityHint = "长按此框，可拖动到日历安排日期"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        badgeContent?.frame = bounds
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let source else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: source.recordURI as NSString))
        item.localObject = source
        let preview = previewContent.makeDragPreview()
        item.previewProvider = { preview }
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        contentPreview(for: item)
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        contentPreview(for: item)
    }

    private func contentPreview(for item: UIDragItem) -> UITargetedDragPreview? {
        guard let preview = item.previewProvider?() else { return nil }
        let target = UIDragPreviewTarget(container: self, center: CGPoint(x: bounds.midX, y: bounds.midY))
        return UITargetedDragPreview(view: preview.view, parameters: preview.parameters, target: target)
    }

    func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating, session: any UIDragSession) {
        animator.addAnimations { [weak badge = badgeContent] in badge?.alpha = 0 }
    }

    func dragInteraction(_ interaction: UIDragInteraction, item: UIDragItem, willAnimateCancelWith animator: any UIDragAnimating) {
        animator.addCompletion { [weak badge = badgeContent] _ in badge?.alpha = 1 }
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        badgeContent?.alpha = 0
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        if operation == .move || operation == .copy {
            badgeContent?.alpha = 1
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
        true
    }

    func dragInteraction(_ interaction: UIDragInteraction, prefersFullSizePreviewsFor session: any UIDragSession) -> Bool {
        true
    }

}
