import UIKit

/// Each task has its own hit target and drag interaction, just like a video tile.
final class VideoCalendarTodoTileView: UIControl {
    private let artwork = UIView()
    private let titleLabel = UILabel()
    private var dragInteraction: UIDragInteraction?
    private(set) var todoID: String?
    private(set) var canDrag = false
    var onOpen: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        artwork.isUserInteractionEnabled = false
        artwork.layer.cornerRadius = AppLayout.controlCornerRadius
        artwork.layer.cornerCurve = .continuous
        artwork.layer.borderWidth = 1
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = true
        artwork.addSubview(titleLabel)
        addSubview(artwork)
        addTarget(self, action: #selector(open), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (view: VideoCalendarTodoTileView, _: UITraitCollection) in view.applyStyle()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(todo: VideoCalendarTodo, dragDelegate: any UIDragInteractionDelegate,
                   onOpen: @escaping () -> Void) {
        todoID = todo.id
        titleLabel.text = todo.title
        canDrag = todo.canEdit
        self.onOpen = onOpen
        if dragInteraction == nil {
            let interaction = UIDragInteraction(delegate: dragDelegate)
            addInteraction(interaction)
            dragInteraction = interaction
        }
        dragInteraction?.isEnabled = canDrag
        accessibilityLabel = "待办，\(todo.title)"
        accessibilityHint = canDrag ? "轻点查看或修改日期，长按拖动调整日期" : "轻点查看，只读待办不能拖动"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: canDrag ? "修改日期" : "查看详情") { [weak self] _ in
            self?.onOpen?()
            return self != nil
        }]
        applyStyle()
    }

    private func applyStyle() {
        titleLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11.5, weight: .medium))
        titleLabel.textColor = .label
        artwork.backgroundColor = .secondarySystemBackground
        artwork.layer.borderColor = AppTheme.readablePrimaryUIColor.resolvedColor(with: traitCollection)
            .withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.35).cgColor
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { artwork.alpha = isHighlighted ? 0.65 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        artwork.frame = bounds.insetBy(dx: 3, dy: 0)
        titleLabel.frame = artwork.bounds.insetBy(dx: 3, dy: 3)
    }

    @objc private func open() { onOpen?() }

    override func accessibilityActivate() -> Bool {
        onOpen?()
        return onOpen != nil
    }

    func makeDragPreview() -> UIDragPreview {
        layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: artwork.bounds).image { context in
            artwork.layer.render(in: context.cgContext)
        }
        let view = UIImageView(image: image)
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: AppLayout.controlCornerRadius)
        return UIDragPreview(view: view, parameters: parameters)
    }
}
