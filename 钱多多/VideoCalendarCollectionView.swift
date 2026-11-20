import CoreData
import SwiftUI
import UIKit

struct VideoCalendarDragSource {
    enum Kind { case video, todo }
    let scopeID: UUID
    let recordURI: String
    var kind: Kind = .video
}

enum VideoCalendarCellLayout {
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 2
    static let headerHeight: CGFloat = 24
    static let contentGap: CGFloat = 3

    static func tileFrame(in bounds: CGRect) -> CGRect {
        let top = verticalPadding + headerHeight + contentGap
        let side = max(0, min(46, min(bounds.width - horizontalPadding * 2, bounds.height - top - verticalPadding)))
        return CGRect(x: bounds.minX + horizontalPadding, y: bounds.minY + top, width: side, height: side)
    }
}

/// Dates stay fixed; videos and tasks own independent native drag interactions.
struct VideoCalendarCollectionView: UIViewRepresentable {
    @Environment(\.appThemeColor) private var appThemeColor
    let days: [Date?]
    let groups: [VideoGroup]
    let todos: [VideoCalendarTodo]
    let dragScope: UUID
    let weekHeights: [CGFloat]
    let todoHeight: CGFloat
    let expandedDays: Set<Date>
    let openVideo: (VideoGroup) -> Void
    let openTodo: (String) -> Void
    let toggleTodos: (Date) -> Void
    let generateBrandImage: (String) -> Void
    let addVideo: (Date) -> Void
    let resolveDestination: (String, Date) -> Date?
    let moveVideo: (String, Date) -> Date?
    let moveTodo: (String, Date) -> Date?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout(weekHeights: weekHeights))
        collectionView.backgroundColor = .clear
        collectionView.isScrollEnabled = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.dropDelegate = context.coordinator
        collectionView.dragInteractionEnabled = false
        collectionView.register(VideoCalendarDayCell.self, forCellWithReuseIdentifier: VideoCalendarDayCell.reuseIdentifier)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        _ = appThemeColor
        let coordinator = context.coordinator
        let daysChanged = coordinator.parent.days != days
        let heightChanged = coordinator.parent.weekHeights != weekHeights
        coordinator.update(parent: self)
        if heightChanged {
            collectionView.setCollectionViewLayout(Self.layout(weekHeights: weekHeights), animated: false)
        }
        if daysChanged {
            collectionView.reloadData()
        } else {
            // Keep the source cell and native drag session alive during updates.
            for case let cell as VideoCalendarDayCell in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell) else { continue }
                coordinator.configure(cell, at: indexPath)
            }
        }
    }

    private static func layout(weekHeights: [CGFloat]) -> UICollectionViewLayout {
        let weeks = weekHeights.map { height in
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / 7), heightDimension: .fractionalHeight(1)
            ))
            return NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                subitems: Array(repeating: item, count: 7)
            )
        }
        let month = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(max(1, weekHeights.reduce(0, +)))),
            subitems: weeks
        )
        return UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: month))
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIDragInteractionDelegate, UICollectionViewDropDelegate {
        var parent: VideoCalendarCollectionView
        private var groupsByDay: [Date: [VideoGroup]] = [:]
        private var todosByDay: [Date: [VideoCalendarTodo]] = [:]
        private var targetedIndexPath: IndexPath?
        private var targetedKind: VideoCalendarDragSource.Kind = .video
        private var isDraggingItem = false

        init(parent: VideoCalendarCollectionView) {
            self.parent = parent
            super.init()
            update(parent: parent)
        }

        func update(parent: VideoCalendarCollectionView) {
            self.parent = parent
            groupsByDay = parent.groups.reduce(into: [:]) { result, group in
                guard let date = group.monthDate else { return }
                result[dayOnly(date), default: []].append(group)
            }
            todosByDay = Dictionary(grouping: parent.todos, by: \.date)
        }

        private func date(at indexPath: IndexPath) -> Date? {
            guard parent.days.indices.contains(indexPath.item) else { return nil }
            return parent.days[indexPath.item]
        }

        private func group(at indexPath: IndexPath) -> VideoGroup? {
            guard let date = date(at: indexPath) else { return nil }
            return groupsByDay[dayOnly(date)]?.first
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.days.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideoCalendarDayCell.reuseIdentifier, for: indexPath) as! VideoCalendarDayCell
            configure(cell, at: indexPath)
            return cell
        }

        func configure(_ cell: VideoCalendarDayCell, at indexPath: IndexPath) {
            let date = date(at: indexPath)
            cell.configure(
                date: date, group: group(at: indexPath),
                todos: date.flatMap { todosByDay[dayOnly($0)] } ?? [],
                expanded: date.map { parent.expandedDays.contains(dayOnly($0)) } ?? false,
                todoHeight: parent.todoHeight,
                showsBottomSeparator: indexPath.item < parent.days.count - 7,
                dragDelegate: self, generateBrandImage: parent.generateBrandImage,
                openTodo: parent.openTodo,
                toggleTodos: { [weak self] in
                    guard let self, let date, !self.isDraggingItem else { return }
                    self.parent.toggleTodos(dayOnly(date))
                }
            )
            cell.setDropTarget(indexPath == targetedIndexPath, kind: targetedKind)
            cell.onActivate = { [weak self] in self?.activate(at: indexPath) ?? false }
        }

        private func activate(at indexPath: IndexPath) -> Bool {
            guard let date = date(at: indexPath) else { return false }
            if let group = group(at: indexPath) {
                parent.openVideo(group)
            } else {
                parent.addVideo(date)
            }
            return true
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard !isDraggingItem else { return }
            _ = activate(at: indexPath)
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            let source: VideoCalendarDragSource
            let preview: UIDragPreview
            if let tile = interaction.view as? VideoCalendarTileView, tile.canDrag, let id = tile.recordURI {
                source = VideoCalendarDragSource(scopeID: parent.dragScope, recordURI: id)
                preview = tile.artwork.makeDragPreview()
            } else if let tile = interaction.view as? VideoCalendarTodoTileView, tile.canDrag, let id = tile.todoID {
                source = VideoCalendarDragSource(scopeID: parent.dragScope, recordURI: id, kind: .todo)
                preview = tile.makeDragPreview()
            } else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider(object: source.recordURI as NSString))
            item.localObject = source
            item.previewProvider = { preview }
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
            true
        }

        func dragInteraction(_ interaction: UIDragInteraction, prefersFullSizePreviewsFor session: any UIDragSession) -> Bool {
            true
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
            contentPreview(for: item, in: interaction.view)
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
            contentPreview(for: item, in: interaction.view)
        }

        private func contentPreview(for item: UIDragItem, in source: UIView?) -> UITargetedDragPreview? {
            guard let source, let preview = item.previewProvider?() else { return nil }
            let target = UIDragPreviewTarget(container: source, center: CGPoint(x: source.bounds.midX, y: source.bounds.midY))
            return UITargetedDragPreview(view: preview.view, parameters: preview.parameters, target: target)
        }

        func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating, session: any UIDragSession) {
            isDraggingItem = true
            animator.addAnimations { [weak source = interaction.view] in source?.alpha = 0 }
        }

        func dragInteraction(_ interaction: UIDragInteraction, item: UIDragItem, willAnimateCancelWith animator: any UIDragAnimating) {
            animator.addCompletion { [weak source = interaction.view] _ in source?.alpha = 1 }
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
            isDraggingItem = true
            interaction.view?.alpha = 0
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            if operation == .move || operation == .copy {
                interaction.view?.alpha = 1
            }
            isDraggingItem = false
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
            guard session.localDragSession != nil, session.items.count == 1,
                  let source = session.items.first?.localObject as? VideoCalendarDragSource else { return false }
            return source.scopeID == parent.dragScope
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            // Hit-test the actual day; insertion positions can point at a neighboring date.
            guard self.collectionView(collectionView, canHandle: session),
                  let source = session.items.first?.localObject as? VideoCalendarDragSource,
                  let indexPath = collectionView.indexPathForItem(at: session.location(in: collectionView)),
                  let requestedDate = date(at: indexPath) else {
                setTarget(nil, in: collectionView)
                return UICollectionViewDropProposal(operation: .forbidden)
            }
            let resolvedDate = source.kind == .todo ? requestedDate : parent.resolveDestination(source.recordURI, requestedDate)
            let resolvedIndex = resolvedDate
                .flatMap { self.indexPath(for: $0) }
            setTarget(resolvedIndex, kind: source.kind, in: collectionView)
            // On release the save handler reports a full month or changed data,
            // rather than failing silently when no valid destination is available.
            // Calendar dates stay fixed. Only a video's schedule moves, so no insertion gap.
            return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
            defer { setTarget(nil, in: collectionView) }
            guard let item = coordinator.items.first, coordinator.items.count == 1,
                  let source = item.dragItem.localObject as? VideoCalendarDragSource, source.scopeID == parent.dragScope,
                  let indexPath = collectionView.indexPathForItem(at: coordinator.session.location(in: collectionView)),
                  let date = date(at: indexPath) else { return }
            let result = source.kind == .todo ? parent.moveTodo(source.recordURI, date) : parent.moveVideo(source.recordURI, date)
            if let resolvedDate = result,
               let resolvedIndex = self.indexPath(for: resolvedDate) {
                let bounds = collectionView.cellForItem(at: resolvedIndex)?.bounds
                    ?? CGRect(x: 0, y: 0, width: collectionView.bounds.width / 7, height: parent.weekHeights[resolvedIndex.item / 7])
                let target: CGRect
                if source.kind == .todo {
                    let top = min(VideoCalendarContentLayout.todoTop(hasVideo: group(at: resolvedIndex) != nil), max(0, bounds.height - parent.todoHeight))
                    target = CGRect(x: 3, y: top, width: max(0, bounds.width - 6), height: parent.todoHeight)
                } else {
                    target = VideoCalendarCellLayout.tileFrame(in: bounds)
                }
                coordinator.drop(item.dragItem, intoItemAt: resolvedIndex, rect: target)
            }
        }

        private func indexPath(for date: Date) -> IndexPath? {
            parent.days.firstIndex { $0.map { qddCalendar.isDate($0, inSameDayAs: date) } ?? false }
                .map { IndexPath(item: $0, section: 0) }
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: any UIDropSession) {
            setTarget(nil, in: collectionView)
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: any UIDropSession) {
            setTarget(nil, in: collectionView)
        }

        private func setTarget(_ indexPath: IndexPath?, kind: VideoCalendarDragSource.Kind = .video, in collectionView: UICollectionView) {
            guard indexPath != targetedIndexPath || kind != targetedKind else { return }
            if let previous = targetedIndexPath, let cell = collectionView.cellForItem(at: previous) as? VideoCalendarDayCell {
                cell.setDropTarget(false)
            }
            targetedIndexPath = indexPath
            targetedKind = kind
            if let indexPath, let cell = collectionView.cellForItem(at: indexPath) as? VideoCalendarDayCell {
                cell.setDropTarget(true, kind: kind)
            }
        }
    }
}

final class VideoCalendarDayCell: UICollectionViewCell {
    static let reuseIdentifier = "VideoCalendarDayCell"
    var onActivate: (() -> Bool)?
    private let dateLabel = UILabel()
    // Arrival is the only status icon in the date header.
    private let arrivalIcon = UIImageView(image: UIImage(systemName: "shippingbox.fill"))
    private let bottomSeparator = CALayer()
    private let dropTarget = CAShapeLayer()
    private var showsBottomSeparator = true
    private let videoTile = VideoCalendarTileView()
    private var todoTiles: [String: VideoCalendarTodoTileView] = [:]
    private var visibleTodoIDs: [String] = []
    private let moreTodosButton = UIButton(type: .system)
    private var onToggleTodos: (() -> Void)?
    private var hasVideo = false
    private var todoHeight: CGFloat = 48
    private var dropKind: VideoCalendarDragSource.Kind = .video
    private lazy var dayAccessibility = VideoCalendarDayAccessibilityElement(accessibilityContainer: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        dateLabel.textAlignment = .center
        dateLabel.layer.masksToBounds = true
        dateLabel.isUserInteractionEnabled = false
        arrivalIcon.contentMode = .scaleAspectFit
        arrivalIcon.tintColor = UIColor(Color.pink)
        arrivalIcon.isUserInteractionEnabled = false
        dropTarget.isHidden = true
        dropTarget.lineWidth = 1
        dropTarget.lineDashPattern = [3, 2]
        contentView.layer.addSublayer(dropTarget)
        contentView.addSubview(dateLabel)
        contentView.addSubview(arrivalIcon)
        contentView.addSubview(videoTile)
        moreTodosButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption2)
        moreTodosButton.titleLabel?.adjustsFontForContentSizeCategory = true
        moreTodosButton.addTarget(self, action: #selector(toggleTodos), for: .touchUpInside)
        moreTodosButton.isHidden = true
        contentView.addSubview(moreTodosButton)
        contentView.layer.addSublayer(bottomSeparator)
        backgroundConfiguration = .clear()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(date: Date?, group: VideoGroup?, todos: [VideoCalendarTodo], expanded: Bool,
                   todoHeight: CGFloat, showsBottomSeparator: Bool, dragDelegate: any UIDragInteractionDelegate,
                   generateBrandImage: @escaping (String) -> Void, openTodo: @escaping (String) -> Void,
                   toggleTodos: @escaping () -> Void) {
        self.showsBottomSeparator = showsBottomSeparator
        self.todoHeight = todoHeight
        hasVideo = group != nil
        onToggleTodos = toggleTodos
        let isToday = date.map { qddCalendar.isDateInToday($0) } ?? false
        dateLabel.text = date.map { "\(qddCalendar.component(.day, from: $0))" }
        dateLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 13, weight: isToday ? .bold : .medium)
        )
        dateLabel.textColor = isToday ? AppTheme.onPrimaryUIColor : .label
        dateLabel.backgroundColor = isToday ? AppTheme.primaryUIColor : .clear
        dateLabel.isHidden = date == nil
        arrivalIcon.isHidden = date == nil || group?.allArrived != true
        videoTile.configure(group: group, dragDelegate: dragDelegate, generateBrandImage: generateBrandImage)
        let visibleTodos = expanded ? todos : Array(todos.prefix(VideoCalendarContentLayout.collapsedTodoLimit))
        visibleTodoIDs = visibleTodos.map(\.id)
        let visibleIDs = Set(visibleTodoIDs)
        for (id, tile) in todoTiles where !visibleIDs.contains(id) {
            // Keep a lifted source alive until UIKit ends its drag session.
            tile.isHidden = true
            if tile.alpha != 0 {
                tile.removeFromSuperview()
                todoTiles.removeValue(forKey: id)
            }
        }
        for todo in visibleTodos {
            let tile = todoTiles[todo.id] ?? VideoCalendarTodoTileView()
            if tile.superview == nil { contentView.addSubview(tile) }
            todoTiles[todo.id] = tile
            tile.isHidden = false
            tile.configure(todo: todo, dragDelegate: dragDelegate) { openTodo(todo.id) }
        }
        moreTodosButton.isHidden = todos.count <= VideoCalendarContentLayout.collapsedTodoLimit
        moreTodosButton.setTitle(expanded ? "收起" : "+\(todos.count - visibleTodos.count)项", for: .normal)
        moreTodosButton.tintColor = AppTheme.readablePrimaryUIColor
        moreTodosButton.accessibilityLabel = expanded ? "收起当天待办" : "展开其余\(todos.count - visibleTodos.count)条待办"
        setNeedsLayout()
        isAccessibilityElement = false
        dayAccessibility.accessibilityTraits = .button
        dayAccessibility.onActivate = { [weak self] in self?.onActivate?() ?? false }
        if let date {
            dayAccessibility.accessibilityLabel = [
                chineseDateText(date), group?.title ?? "暂无排期",
                group.map { $0.allPublished ? "已发布" : "待发布" } ?? "",
                group.map { $0.allArrived ? "全部到货" : "未全部到货" } ?? ""
            ].filter { !$0.isEmpty }.joined(separator: "，")
            dayAccessibility.accessibilityHint = group == nil ? "安排视频" : (group?.allPublished == true
                ? "轻点打开视频，长按复制品牌名或生成图片"
                : "轻点打开视频，长按拖动调整日期")
            if let group, group.allPublished {
                let text = numberedBrandNamesCopyText(group.records.map(\.titleText))
                dayAccessibility.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "复制品牌名") { _ in
                        UIPasteboard.general.string = text
                        return true
                    },
                    UIAccessibilityCustomAction(name: "生成图片") { _ in
                        generateBrandImage(text)
                        return true
                    }
                ]
            } else {
                dayAccessibility.accessibilityCustomActions = nil
            }
            var elements: [Any] = [dayAccessibility]
            elements.append(contentsOf: visibleTodoIDs.compactMap { todoTiles[$0] })
            if !moreTodosButton.isHidden { elements.append(moreTodosButton) }
            accessibilityElements = elements
        } else {
            accessibilityElements = []
        }
    }

    @objc private func toggleTodos() { onToggleTodos?() }

    func setDropTarget(_ isTarget: Bool, kind: VideoCalendarDragSource.Kind = .video) {
        dropKind = kind
        dropTarget.isHidden = !isTarget
        setNeedsLayout()
    }

    override func accessibilityActivate() -> Bool { onActivate?() ?? false }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let headerSide = VideoCalendarCellLayout.headerHeight
        dateLabel.frame = CGRect(
            x: VideoCalendarCellLayout.horizontalPadding,
            y: VideoCalendarCellLayout.verticalPadding,
            width: headerSide,
            height: headerSide
        )
        dateLabel.layer.cornerRadius = headerSide / 2
        let arrivalIconSize: CGFloat = 11
        arrivalIcon.frame = CGRect(
            x: bounds.maxX - VideoCalendarCellLayout.horizontalPadding - arrivalIconSize,
            y: VideoCalendarCellLayout.verticalPadding + (headerSide - arrivalIconSize) / 2,
            width: arrivalIconSize,
            height: arrivalIconSize
        )
        videoTile.frame = VideoCalendarCellLayout.tileFrame(in: bounds)
        let top = VideoCalendarContentLayout.todoTop(hasVideo: hasVideo)
        for (index, id) in visibleTodoIDs.enumerated() {
            todoTiles[id]?.frame = CGRect(x: 0, y: top + CGFloat(index) * (todoHeight + VideoCalendarContentLayout.gap),
                                         width: bounds.width, height: todoHeight)
        }
        moreTodosButton.frame = CGRect(x: 0, y: top + CGFloat(visibleTodoIDs.count) * (todoHeight + VideoCalendarContentLayout.gap),
                                       width: bounds.width, height: todoHeight)
        dayAccessibility.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: bounds.width,
                                                                    height: hasVideo ? videoTile.frame.maxY : VideoCalendarContentLayout.contentTop)
        let isDark = traitCollection.userInterfaceStyle == .dark
        backgroundColor = .clear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineWidth = 1 / max(1, traitCollection.displayScale)
        bottomSeparator.backgroundColor = UIColor.label.resolvedColor(with: traitCollection)
            .withAlphaComponent(isDark ? 0.09 : 0.055).cgColor
        bottomSeparator.frame = CGRect(x: 0, y: bounds.maxY - lineWidth, width: bounds.width, height: lineWidth)
        bottomSeparator.isHidden = !showsBottomSeparator
        dropTarget.frame = dropKind == .todo ? bounds.insetBy(dx: 1, dy: 1) : videoTile.frame.insetBy(dx: -1, dy: -1)
        dropTarget.path = UIBezierPath(roundedRect: dropTarget.bounds, cornerRadius: AppLayout.controlCornerRadius + 1).cgPath
        dropTarget.fillColor = AppTheme.primaryUIColor.withAlphaComponent(0.08).cgColor
        dropTarget.strokeColor = AppTheme.readablePrimaryUIColor.resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
        dateLabel.text = nil
        arrivalIcon.isHidden = true
        videoTile.reset()
        todoTiles.values.forEach { $0.removeFromSuperview() }
        todoTiles.removeAll()
        visibleTodoIDs = []
        moreTodosButton.isHidden = true
        onToggleTodos = nil
        accessibilityElements = []
        setDropTarget(false)
    }
}

private final class VideoCalendarDayAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}

final class VideoCalendarTileView: UIView, UIContextMenuInteractionDelegate {
    let artwork = VideoCalendarTileArtwork()
    private var dragInteraction: UIDragInteraction?
    private var contextMenuInteraction: UIContextMenuInteraction?
    private(set) var recordURI: String?
    private(set) var canDrag = false
    private var brandNamesText: String?
    private var generateBrandImage: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        artwork.isUserInteractionEnabled = false
        addSubview(artwork)
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(group: VideoGroup?, dragDelegate: any UIDragInteractionDelegate, generateBrandImage: @escaping (String) -> Void) {
        guard let group, let record = group.records.first else {
            reset()
            return
        }
        recordURI = record.objectID.uriRepresentation().absoluteString
        isHidden = false
        // Copy current values from Core Data on every refresh, including reused cells.
        artwork.configure(title: group.title, isPublished: group.allPublished)
        canDrag = !group.allPublished
        brandNamesText = group.allPublished ? numberedBrandNamesCopyText(group.records.map(\.titleText)) : nil
        self.generateBrandImage = group.allPublished ? generateBrandImage : nil
        if dragInteraction == nil {
            let interaction = UIDragInteraction(delegate: dragDelegate)
            addInteraction(interaction)
            dragInteraction = interaction
        }
        dragInteraction?.isEnabled = canDrag
        if group.allPublished {
            if contextMenuInteraction == nil {
                let interaction = UIContextMenuInteraction(delegate: self)
                addInteraction(interaction)
                contextMenuInteraction = interaction
            }
        } else if let contextMenuInteraction {
            removeInteraction(contextMenuInteraction)
            self.contextMenuInteraction = nil
        }
        setNeedsLayout()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !canDrag, let text = brandNamesText, let generateBrandImage else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "复制品牌名", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
                UIAction(title: "生成图片", image: UIImage(systemName: "photo.badge.plus")) { _ in
                    generateBrandImage(text)
                }
            ])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        menuPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        menuPreview()
    }

    private func menuPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: artwork.bounds, cornerRadius: AppLayout.controlCornerRadius)
        return UITargetedPreview(view: artwork, parameters: parameters)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        artwork.frame = bounds
    }

    func reset() {
        alpha = 1
        recordURI = nil
        canDrag = false
        brandNamesText = nil
        generateBrandImage = nil
        if let contextMenuInteraction {
            removeInteraction(contextMenuInteraction)
            self.contextMenuInteraction = nil
        }
        isHidden = true
        dragInteraction?.isEnabled = false
    }
}
