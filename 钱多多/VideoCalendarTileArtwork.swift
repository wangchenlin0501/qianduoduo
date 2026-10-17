import UIKit

/// Content artwork only: dates and status icons never enter its drag snapshot.
final class VideoCalendarTileArtwork: UIView {
    private let titleLabel = UILabel()
    private let gradient = CAGradientLayer()
    private var isPublished = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = AppLayout.controlCornerRadius
        layer.cornerCurve = .continuous
        gradient.cornerRadius = AppLayout.controlCornerRadius
        gradient.cornerCurve = .continuous
        gradient.startPoint = CGPoint(x: 0.2, y: 0)
        gradient.endPoint = CGPoint(x: 0.8, y: 1)
        layer.addSublayer(gradient)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 3
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (view: VideoCalendarTileArtwork, _: UITraitCollection) in
            view.applyStyle()
        }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, isPublished: Bool) {
        titleLabel.text = title
        self.isPublished = isPublished
        applyStyle()
    }

    private func applyStyle() {
        titleLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11.5, weight: .semibold))
        titleLabel.textColor = isPublished ? .secondaryLabel : AppTheme.onPrimaryUIColor
        backgroundColor = isPublished ? .tertiarySystemFill : .clear
        gradient.isHidden = isPublished
        let accent = AppTheme.primaryUIColor.resolvedColor(with: traitCollection)
        gradient.colors = [accent.withAlphaComponent(0.94).cgColor, accent.cgColor]
        layer.shadowColor = accent.cgColor
        layer.shadowOpacity = isPublished ? 0 : 0.10
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: AppLayout.controlCornerRadius).cgPath
        CATransaction.commit()
        titleLabel.frame = bounds.insetBy(dx: 3, dy: 3)
    }

    func makeDragPreview() -> UIDragPreview {
        layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { context in layer.render(in: context.cgContext) }
        let imageView = UIImageView(image: image)
        imageView.bounds = bounds
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: imageView.bounds, cornerRadius: AppLayout.controlCornerRadius)
        return UIDragPreview(view: imageView, parameters: parameters)
    }
}
