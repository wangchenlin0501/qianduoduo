import SwiftUI
import UIKit

/// Observes taps without placing a hit-testing layer over the chart or its scroll view.
struct ChartSelectionDismissObserver: UIViewRepresentable {
    @Binding var selection: Double?

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.selection = $selection
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.selection = $selection
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) {
        uiView.detach()
    }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var selection: Binding<Double?>?
        private weak var observedWindow: UIWindow?
        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissSelection))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            observedWindow = window
            window?.addGestureRecognizer(tap)
        }

        func detach() {
            observedWindow?.removeGestureRecognizer(tap)
            observedWindow = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Decide at touch-down, so the tap that opens a value cannot also dismiss it.
            selection?.wrappedValue != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func dismissSelection() {
            // Clear after the chart's own tap callback, irrespective of callback order.
            DispatchQueue.main.async { [weak self] in
                self?.selection?.wrappedValue = nil
            }
        }
    }
}
