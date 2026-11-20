import SwiftUI
import UIKit

/// Observes the empty area of a List or Form without adding a hit-testing layer.
/// Install as a background of the scroll view so its bounds define the viewport.
struct TodoKeyboardDismissObserver: UIViewRepresentable {
    var enabled: Bool
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.configure(enabled: enabled, onDismiss: onDismiss)
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.configure(enabled: enabled, onDismiss: onDismiss)
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) {
        uiView.detach()
    }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        private var enabled = false
        private var onDismiss: (() -> Void)?
        private weak var observedView: UIView?
        private weak var owningController: UIViewController?

        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        func configure(enabled: Bool, onDismiss: @escaping () -> Void) {
            self.enabled = enabled
            self.onDismiss = onDismiss
            attachIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard window != nil else {
                detach()
                return
            }

            // A controller's view scopes the recognizer to this screen. A window
            // recognizer would also see touches in a sheet presented above it.
            var responder: UIResponder? = next
            var controller: UIViewController?
            while let current = responder {
                if let current = current as? UIViewController {
                    controller = current
                    break
                }
                responder = current.next
            }
            guard let scope = controller?.view, scope !== self else { return }
            guard observedView !== scope else {
                owningController = controller
                return
            }
            detach()
            owningController = controller
            observedView = scope
            scope.addGestureRecognizer(tap)
        }

        func detach() {
            observedView?.removeGestureRecognizer(tap)
            observedView = nil
            owningController = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Decide at touch-down. An initial tap that starts editing must never
            // become a dismissal after SwiftUI updates `enabled` for that tap.
            guard enabled, let scope = observedView, let touchedView = touch.view,
                  touchedView.isDescendant(of: scope), window === touchedView.window,
                  !isHidden, alpha > 0, !bounds.isEmpty,
                  bounds.contains(touch.location(in: self)),
                  !isCoveredByPresentation() else { return false }

            var ancestor: UIView? = touchedView
            while let view = ancestor {
                // Exclude whole rows, including the SwiftUI Text which becomes a
                // TextField on the first tap and has no UIKit control ancestor yet.
                if view is UITableViewCell || view is UICollectionViewCell
                    || view is UIControl || view is UITextView
                    || view is UIPickerView || view is UISearchBar
                    || view is UINavigationBar || view is UIToolbar {
                    return false
                }
                // SwiftUI buttons may expose accessibility without a UIControl.
                if view.accessibilityTraits.contains(.button)
                    || view.accessibilityTraits.contains(.adjustable) {
                    return false
                }
                if view === scope { break }
                ancestor = view.superview
            }
            return true
        }

        private func isCoveredByPresentation() -> Bool {
            var controller = owningController
            while let current = controller {
                if let presented = current.presentedViewController,
                   let presentedView = presented.viewIfLoaded,
                   !isDescendant(of: presentedView) {
                    return true
                }
                controller = current.parent
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func dismissKeyboard() {
            guard enabled else { return }
            // UIKit delivers gesture actions on the main thread. Keep the
            // callback synchronous so a later tap cannot open another editor
            // before an old, queued dismissal runs.
            onDismiss?()
        }
    }
}
