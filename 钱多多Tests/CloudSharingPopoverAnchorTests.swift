import Testing
import UIKit
@testable import 钱多多

@MainActor
struct CloudSharingPopoverAnchorTests {
    @Test func suppliesIPadPopoverWithSettingsSourceAndNonemptyRect() throws {
        let anchor = CloudSharingPopoverAnchor()
        let controller = UIViewController()

        anchor.configure(controller)

        let popover = try #require(controller.popoverPresentationController)
        #expect(controller.modalPresentationStyle == .popover)
        #expect(popover.sourceView === anchor.sourceView)
        #expect(!popover.sourceRect.isEmpty)
        #expect(popover.permittedArrowDirections.isEmpty)
    }

    @Test func followsSourceLayoutAndRotationWithoutReplacingTheController() throws {
        let anchor = CloudSharingPopoverAnchor()
        let controller = UIViewController()
        anchor.configure(controller)
        let popover = try #require(controller.popoverPresentationController)

        anchor.sourceView.bounds = CGRect(x: 0, y: 0, width: 320, height: 44)
        anchor.sourceView.setNeedsLayout()
        anchor.sourceView.layoutIfNeeded()
        #expect(popover.sourceRect == anchor.sourceView.bounds)

        anchor.sourceView.bounds = CGRect(x: 0, y: 0, width: 600, height: 60)
        anchor.sourceView.setNeedsLayout()
        anchor.sourceView.layoutIfNeeded()
        #expect(popover.sourceView === anchor.sourceView)
        #expect(popover.sourceRect == anchor.sourceView.bounds)
    }
}
