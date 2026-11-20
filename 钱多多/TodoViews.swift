import CoreData
import SwiftUI

private enum TodoSort: String, CaseIterable, Identifiable {
    case manual = "手动"
    case due = "日期"
    case created = "创建日期"
    case title = "标题"
    var id: String { rawValue }
    var label: String { self == .due ? "截止日期" : rawValue }
}

struct TodoPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = TodoStore()
    @AppStorage("todoShowCompleted") private var showCompleted = true
    @AppStorage("todoSort") private var sort: TodoSort = .manual
    @State private var titleScrolled = false
    @State private var isAdding = false
    @State private var draftTitle = ""
    @State private var draftDate: Date?
    @State private var draftLink: TodoContentLink?
    @State private var showingDraftLink = false
    @State private var linkedRecords: [AdRecord] = []
    @State private var linkedDestination: TodoLinkDestinationSelection?
    @State private var showingDraftDate = false
    @State private var activeEditor: NSManagedObjectID?
    @State private var selectedItem: TodoItem?
    @State private var clearConfirmation = false
    @State private var clearAfterConfirmationDismissed = false
    @State private var inputCommitID = UUID()
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var completionFeedback = 0
    @State private var isPressHolding = false
    @FocusState private var draftFocused: Bool
    @FocusState private var searchFocused: Bool

    private var displayedItems: [TodoItem] {
        sorted(store.items.filter {
            matchesSearch($0) && ($0.completedAt == nil || showsCompletedRows)
        })
    }
    private var completedCount: Int { store.items.filter { $0.completedAt != nil }.count }
    private var activeItems: [TodoItem] { displayedItems.filter { $0.completedAt == nil } }
    private var completedItems: [TodoItem] { displayedItems.filter { $0.completedAt != nil } }
    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showsCompletedRows: Bool { showCompleted || !searchQuery.isEmpty }
    private var isEnteringText: Bool { isAdding || activeEditor != nil }
    private var canReorder: Bool {
        sort == .manual && !isEnteringText && !searchPresented && searchQuery.isEmpty
            && store.items.allSatisfy { store.canEdit($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    headerRows

                    let active = activeItems
                    let completed = completedItems

                    ForEach(active, id: \.objectID) { item in
                        row(item)
                    }
                    .onMove { offsets, destination in
                        moveItems(in: active, from: offsets, to: destination)
                    }
                    .moveDisabled(!canReorder)

                    if isAdding {
                        draftRow
                            .id("todo-draft")
                    }

                    if !completed.isEmpty {
                        completedHeader(count: completed.count)
                    }

                    ForEach(completed, id: \.objectID) { item in
                        row(item)
                    }
                    .onMove { offsets, destination in
                        moveItems(in: completed, from: offsets, to: destination)
                    }
                    .moveDisabled(!canReorder)

                    if store.items.isEmpty && !isAdding {
                        ContentUnavailableView(
                            "还没有待办",
                            systemImage: "checklist",
                            description: Text(store.canCreate ? "轻点右下角的 ＋，添加第一项待办" : "当前共享仅可查看待办")
                        )
                        .listRowSeparator(.hidden)
                    } else if !searchQuery.isEmpty && displayedItems.isEmpty && !isAdding {
                        ContentUnavailableView.search(text: searchQuery)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .background(ListPressHoldObserver(isHolding: $isPressHolding))
                .listRowBackground(Color.clear)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemBackground))
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > 60
                } action: { _, value in
                    titleScrolled = value
                }
                // Keep the list's geometry stable when editing begins. The add
                // button is an overlay, not a disappearing safe-area inset.
                .contentMargins(.bottom, 104, for: .scrollContent)
                .background {
                    TodoKeyboardDismissObserver(enabled: isEnteringText || searchPresented) {
                        finishInput()
                        searchFocused = false
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if searchPresented {
                        searchBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } else if !isEnteringText {
                        Button(action: beginAdding) {
                            Image(systemName: "plus")
                                .font(.title.weight(.medium))
                                .foregroundStyle(AppTheme.onPrimary)
                                .frame(width: 52, height: 52)
                                .background(AppTheme.primary, in: Circle())
                                .shadow(color: AppTheme.primary.opacity(0.28), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加待办")
                        .disabled(!store.canCreate)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                    }
                }
                .onChange(of: isAdding) { _, adding in
                    guard adding else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo("todo-draft", anchor: .bottom)
                        draftFocused = true
                    }
                }
            }
            .navigationTitle(titleScrolled ? "ToDo List" : "")
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.readablePrimary)
            .sensoryFeedback(.impact(weight: .medium, intensity: 1), trigger: completionFeedback)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    moreMenu
                    if isEnteringText {
                        Button("完成", systemImage: "checkmark", role: todoConfirmationRole) { finishInput() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("完成输入")
                    } else {
                        Button("搜索", systemImage: "magnifyingglass", action: beginSearch)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.primary)
                            .tint(Color.primary)
                            .accessibilityLabel("搜索待办和关联内容")
                    }
                }
            }
            .sheet(item: $selectedItem) { item in
                TodoDetailsEditor(item: item, store: store)
            }
            .sheet(isPresented: $showingDraftDate) {
                TodoDateEditor(date: draftDate) { draftDate = $0 }
            }
            .sheet(isPresented: $showingDraftLink) {
                TodoContentLinkPicker(store: store, selection: draftLink) { draftLink = $0 }
            }
            .sheet(item: $linkedDestination) { destination in
                TodoContentLinkDestination(store: store, link: destination.link, spaceID: destination.spaceID)
            }
            .alert(clearConfirmation ? "清除全部已完成待办？" : "无法保存待办", isPresented: Binding(
                get: { clearConfirmation || store.errorMessage != nil },
                set: { presented in
                    guard !presented else { return }
                    if clearConfirmation { clearConfirmation = false }
                    else { store.errorMessage = nil }
                }
            )) {
                if clearConfirmation {
                    Button("清除已完成", role: .destructive) {
                        clearAfterConfirmationDismissed = true
                    }
                    Button("取消", role: .cancel) { }
                } else {
                    Button("好") { store.errorMessage = nil }
                }
            } message: {
                Text(clearConfirmation ? "已完成待办将从当前数据空间中删除。" : (store.errorMessage ?? "请稍后重试。"))
            }
            .onChange(of: clearConfirmation) { _, presented in
                guard !presented, clearAfterConfirmationDismissed else { return }
                clearAfterConfirmationDismissed = false
                // Let the confirmation presenter close before an unsuccessful
                // save needs to open the error alert on the same presenter.
                Task { @MainActor in
                    await Task.yield()
                    finishInput()
                    perform { try store.deleteCompleted() }
                }
            }
            .onDisappear { finishInput() }
            .task { refreshLinkedRecords() }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                refreshLinkedRecords()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: store.context)) { note in
                // A read can emit refreshed-object notifications itself; only
                // react to actual merged content changes to avoid refetch loops.
                let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
                let contentChanged = keys.contains { key in
                    (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is AdRecord || $0 is SyncSpace } == true
                }
                if contentChanged || note.userInfo?[NSInvalidatedAllObjectsKey] != nil {
                    Task { @MainActor in refreshLinkedRecords() }
                }
            }
            .onChange(of: sort) { _, _ in
                finishInput()
                TodoWidgetBridge.shared.requestRefresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    finishInput()
                    searchFocused = false
                }
                else { perform { try store.refresh() }; refreshLinkedRecords() }
            }
        }
    }

    @ViewBuilder
    private var headerRows: some View {
        // Keep the Reminders-style title within the app's selected theme.
        Text("ToDo List")
            .font(.largeTitle.bold())
            .foregroundStyle(AppTheme.readablePrimary)
            .accessibilityAddTraits(.isHeader)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

        if !store.items.isEmpty || isAdding {
            HStack(spacing: 8) {
                Text(completedCount > 0 ? "\(completedCount) 项已完成 ·" : "0 项已完成")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("清除") { clearConfirmation = true }
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(completedCount > 0 ? 1 : 0)
                    .accessibilityHidden(completedCount == 0)
                    .disabled(completedCount == 0 || !store.items.filter { $0.completedAt != nil }.allSatisfy { store.canEdit($0) })
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
        }

    }

    private func completedHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("已完成")
            Text("\(count)")
                .monospacedDigit()
            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.6))
                .frame(height: 0.5)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var moreMenu: some View {
        Menu {
            Picker(selection: $sort) {
                ForEach(TodoSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                Label("排序方式", systemImage: "arrow.up.arrow.down")
                Text(sort.label)
            }
            .pickerStyle(.menu)
            Button {
                finishInput()
                showCompleted.toggle()
            } label: {
                Label(showCompleted ? "隐藏已完成项目" : "显示已完成项目",
                      systemImage: showCompleted ? "eye.slash" : "eye")
            }
            if completedCount > 0 {
                Button("清除已完成", systemImage: "trash", role: .destructive) {
                    clearConfirmation = true
                }
                .disabled(!store.items.filter { $0.completedAt != nil }.allSatisfy { store.canEdit($0) })
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.primary)
        }
        .tint(Color.primary)
        .menuOrder(.fixed)
        .accessibilityLabel("待办选项")
    }

    private func row(_ item: TodoItem) -> some View {
        TodoListRow(
            item: item, canEdit: store.canEdit(item), commitID: inputCommitID,
            commit: { title in
                do { try store.rename(item, title: title); return true }
                catch { store.errorMessage = error.localizedDescription; return false }
            },
            toggle: {
                finishInput()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    perform {
                        try store.toggleCompletion(item)
                        completionFeedback &+= 1
                    }
                }
            },
            details: {
                finishInput()
                selectedItem = item
            },
            editingChanged: { focused in
                if focused {
                    searchFocused = false
                    activeEditor = item.objectID
                }
                else if activeEditor == item.objectID { activeEditor = nil }
            },
            next: beginAdding,
            linkedRecords: linkedRecords,
            collapsesDetails: isPressHolding && canReorder,
            openLink: {
                finishInput()
                guard let link = item.contentLink, let spaceID = item.syncSpace?.objectID,
                      store.items.contains(where: { $0.objectID == item.objectID }) else { return }
                linkedDestination = TodoLinkDestinationSelection(link: link, spaceID: spaceID)
            }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) {
                finishInput()
                perform { try store.delete(item) }
            }
            .tint(AppTheme.danger)
            .disabled(!store.canEdit(item))
        }
    }

    private var draftRow: some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                commitDraft(continueAdding: true, completed: true)
            } label: {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("完成新待办")

            VStack(alignment: .leading, spacing: 10) {
                TextField("待办事项", text: $draftTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .focused($draftFocused)
                    .submitLabel(.next)
                    .onSubmit { commitDraft(continueAdding: true) }
                    .frame(minHeight: 44)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { draftDateControl; draftLinkControl }
                    VStack(alignment: .leading, spacing: 8) { draftDateControl; draftLinkControl }
                }
                if let draftLink {
                    TodoLinkedContentLabel(link: draftLink, records: linkedRecords)
                }

            }
            .padding(.trailing, 12)
            .padding(.bottom, 16)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private var draftLinkControl: some View {
        Button {
            draftFocused = false
            showingDraftLink = true
        } label: {
            Label(draftLink.map { $0.kind == .video ? "视频" : "池子" } ?? "关联",
                  systemImage: draftLink.map { $0.kind == .video ? "video" : "tray" } ?? "link")
                .font(.subheadline)
                .foregroundStyle(AppTheme.readablePrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draftLink == nil ? "关联视频或池子记录" : "更改关联内容")
    }

    private var draftDateControl: some View {
        Button {
            draftFocused = false
            showingDraftDate = true
        } label: {
            Label(draftDate.map { shortDateText($0) } ?? "日期", systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(AppTheme.readablePrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draftDate == nil ? "设置日期" : "更改日期")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索待办和关联内容", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityLabel("搜索待办和关联内容")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(.regularMaterial, in: Capsule())

            Button {
                searchFocused = false
                searchPresented = false
                searchText = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("结束搜索")
        }
    }

    private func beginSearch() {
        finishInput()
        searchPresented = true
        Task { @MainActor in
            await Task.yield()
            guard searchPresented, !isEnteringText else { return }
            searchFocused = true
        }
    }

    private func refreshLinkedRecords() {
        linkedRecords = (try? store.contentRecords()) ?? []
    }

    private func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { first, second in
            switch sort {
            case .manual:
                if first.sortOrder != second.sortOrder { return first.sortOrder < second.sortOrder }
            case .created:
                if first.createdAt != second.createdAt {
                    return (first.createdAt ?? .distantPast) < (second.createdAt ?? .distantPast)
                }
            case .due:
                if first.dueDate != second.dueDate {
                    return (first.dueDate ?? .distantFuture) < (second.dueDate ?? .distantFuture)
                }
            case .title:
                let comparison = (first.title ?? "").localizedStandardCompare(second.title ?? "")
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if first.createdAt != second.createdAt {
                return (first.createdAt ?? .distantPast) < (second.createdAt ?? .distantPast)
            }
            return (first.id?.uuidString ?? first.objectID.uriRepresentation().absoluteString)
                < (second.id?.uuidString ?? second.objectID.uriRepresentation().absoluteString)
        }
    }

    private func matchesSearch(_ item: TodoItem) -> Bool {
        searchQuery.isEmpty || (item.title ?? "").localizedStandardContains(searchQuery)
            || (item.contentLink?.fallbackTitle ?? "").localizedStandardContains(searchQuery)
            || item.contentLink?.resolvedRecords(in: linkedRecords).contains {
                ($0.brandName ?? "").localizedStandardContains(searchQuery)
                    || ($0.videoTitle ?? "").localizedStandardContains(searchQuery)
            } == true
    }


    private func beginAdding() {
        searchFocused = false
        searchPresented = false
        searchText = ""
        inputCommitID = UUID()
        activeEditor = nil
        if !isAdding { isAdding = true }
        draftFocused = true
    }

    private func finishInput() {
        inputCommitID = UUID()
        activeEditor = nil
        draftFocused = false
        if isAdding { commitDraft(continueAdding: false) }
    }

    private func commitDraft(continueAdding: Bool, completed: Bool = false) {
        do {
            let savedItem = try store.create(title: draftTitle, dueDate: draftDate, link: draftLink)
            draftTitle = ""
            draftDate = nil
            draftLink = nil
            showingDraftDate = false
            isAdding = continueAdding
            draftFocused = continueAdding
            if completed, let savedItem {
                try store.toggleCompletion(savedItem)
                completionFeedback &+= 1
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func moveItems(in group: [TodoItem], from offsets: IndexSet, to destination: Int) {
        guard canReorder, offsets.allSatisfy({ group.indices.contains($0) }),
              (0...group.count).contains(destination) else { return }
        var visibleIDs = group.map(\.objectID)
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)
        guard let fullOrder = TodoRules.mergingVisibleOrder(
            fullOrder: sorted(store.items).map(\.objectID), visibleOrder: visibleIDs
        ) else { return }
        perform { try store.move(ids: fullOrder) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private struct TodoListRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var item: TodoItem
    let canEdit: Bool
    let commitID: UUID
    let commit: (String) -> Bool
    let toggle: () -> Void
    let details: () -> Void
    let editingChanged: (Bool) -> Void
    let next: () -> Void
    let linkedRecords: [AdRecord]
    var collapsesDetails = false
    let openLink: () -> Void
    @State private var title = ""
    @State private var editingOriginal = ""
    @FocusState private var focused: Bool

    private var isCompleted: Bool { item.completedAt != nil }
    private var textAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.18).delay(isCompleted ? 0.06 : 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                guard commitTitle() else { return }
                focused = false
                toggle()
            } label: {
                TodoCompletionIndicator(isCompleted: isCompleted)
                    .frame(width: 44, height: 44)
                    .opacity(isCompleted ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .accessibilityLabel(item.completedAt == nil ? "标记完成" : "恢复待办")
            .accessibilityValue(item.title ?? "待办")

            VStack(alignment: .leading, spacing: 2) {
                TextField("待办事项", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(isCompleted ? Color.secondary : .primary)
                    .animation(textAnimation, value: isCompleted)
                    .focused($focused)
                    .disabled(!canEdit)
                    .submitLabel(.next)
                    .onSubmit {
                        guard commitTitle() else { return }
                        focused = false
                        next()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityHint(canEdit ? "轻点编辑" : "只读待办")
                if !collapsesDetails, let date = item.dueDate {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .frame(width: 16)
                        Text(shortDateText(date))
                    }
                    .font(.footnote)
                    .foregroundStyle(date < dayOnly(Date()) && item.completedAt == nil ? AppTheme.danger : .secondary)
                    .frame(minHeight: 22, alignment: .leading)
                }
                if !collapsesDetails, let link = item.contentLink {
                    Button(action: openLink) {
                        TodoLinkedContentLabel(link: link, records: linkedRecords, compact: true)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开关联内容")
                }
            }
            .padding(.bottom, !collapsesDetails && (item.dueDate != nil || item.contentLink != nil) ? 8 : 0)
            .opacity(isCompleted ? 0.62 : 1)

            Button {
                guard commitTitle() else { return }
                focused = false
                details()
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.readablePrimary)
            .opacity(focused || !canEdit ? 1 : 0)
            .allowsHitTesting(focused || !canEdit)
            .accessibilityHidden(!focused && canEdit)
            .accessibilityLabel("待办详情")
        }
        .onAppear {
            title = item.title ?? ""
            editingOriginal = title
        }
        .onChange(of: item.title) { _, value in
            if !focused && title == editingOriginal {
                title = value ?? ""
                editingOriginal = title
            }
        }
        .onChange(of: focused) { _, value in
            if value {
                // Preserve a failed local save, but refresh an untouched editing buffer.
                if title == editingOriginal { title = item.title ?? "" }
                editingOriginal = item.title ?? ""
            } else {
                commitTitle()
            }
            editingChanged(value)
        }
        .onChange(of: commitID) { _, _ in
            commitTitle()
            focused = false
        }
        .onDisappear {
            commitTitle()
            editingChanged(false)
        }
    }

    @discardableResult
    private func commitTitle() -> Bool {
        guard !item.isDeleted, item.managedObjectContext != nil else { return true }
        if title == editingOriginal || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A remote rename must never be overwritten merely by focusing and blurring.
            title = item.title ?? ""
            editingOriginal = title
            return true
        }
        guard title != (item.title ?? "") else {
            editingOriginal = title
            return true
        }
        guard commit(title) else { return false }
        title = item.title ?? title
        editingOriginal = title
        return true
    }

}

/// Reminders fills the inner disc while keeping the outer ring and row fixed.
private struct TodoCompletionIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isCompleted ? AppTheme.readablePrimary : Color(uiColor: .tertiaryLabel), lineWidth: 1.7)
            Circle()
                .fill(AppTheme.readablePrimary)
                .padding(3.5)
                .scaleEffect(reduceMotion || isCompleted ? 1 : 0.01)
                .opacity(isCompleted ? 1 : 0)
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : (isCompleted ? 0.26 : 0.2)), value: isCompleted)
        .accessibilityHidden(true)
    }
}

struct TodoDetailsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var item: TodoItem
    @ObservedObject var store: TodoStore
    @State private var title: String
    @State private var date: Date?
    @State private var showingDatePicker = false
    @FocusState private var titleFocused: Bool
    @State private var error: String?
    @State private var link: TodoContentLink?
    @State private var showingLinkPicker = false
    @State private var linkedDestination: TodoLinkDestinationSelection?
    @State private var linkedRecords: [AdRecord] = []

    init(item: TodoItem, store: TodoStore) {
        self.item = item
        self.store = store
        _title = State(initialValue: item.title ?? "")
        _date = State(initialValue: item.dueDate)
        _link = State(initialValue: item.contentLink)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title, axis: .vertical)
                        .foregroundStyle(.primary)
                        .focused($titleFocused)
                }
                .disabled(!store.canEdit(item))
                Section {
                    Button {
                        titleFocused = false
                        showingDatePicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Label("日期", systemImage: "calendar")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 12)
                            Text(date.map { shortDateText($0) } ?? "未设置")
                                .foregroundStyle(date == nil ? Color.secondary : AppTheme.readablePrimary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .disabled(!store.canEdit(item))
                Section("关联内容") {
                    if let link {
                        HStack(spacing: 12) {
                            Button {
                                titleFocused = false
                                guard let spaceID = item.syncSpace?.objectID else { return }
                                linkedDestination = TodoLinkDestinationSelection(link: link, spaceID: spaceID)
                            } label: {
                                TodoLinkedContentLabel(link: link, records: linkedRecords)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("更换关联内容", systemImage: "arrow.triangle.2.circlepath") {
                                    titleFocused = false
                                    showingLinkPicker = true
                                }
                                Button("移除关联", systemImage: "minus.circle", role: .destructive) {
                                    self.link = nil
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(!store.canEdit(item))
                            .accessibilityLabel("关联内容选项")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button {
                            titleFocused = false
                            showingLinkPicker = true
                        } label: {
                            Label("关联视频或池子记录", systemImage: "link")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .disabled(!store.canEdit(item))
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                TodoKeyboardDismissObserver(enabled: titleFocused) { titleFocused = false }
            }
            .navigationTitle("待办详情")
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.readablePrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark", role: todoConfirmationRole) {
                        do {
                            // Notes are no longer part of this interface. Keep any
                            // historical value intact when editing other fields.
                            try store.update(item, title: title, notes: item.notes ?? "", dueDate: date, link: link)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!store.canEdit(item) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { linkedRecords = (try? store.contentRecords()) ?? [] }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                linkedRecords = (try? store.contentRecords()) ?? []
            }
            .sheet(isPresented: $showingDatePicker) {
                TodoDateEditor(date: date) { date = $0 }
            }
            .sheet(isPresented: $showingLinkPicker) {
                TodoContentLinkPicker(store: store, selection: link) {
                    link = $0
                    linkedRecords = (try? store.contentRecords()) ?? []
                }
            }
            .sheet(item: $linkedDestination) { destination in
                TodoContentLinkDestination(store: store, link: destination.link, spaceID: destination.spaceID)
            }
            .alert("无法保存待办", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("好") { error = nil } } message: { Text(error ?? "请稍后重试。") }
        }
    }
}

/// A single calendar flow shared by new items and details. Selection stays
/// local until Done; Cancel and swipe-to-dismiss leave the saved date intact.
private struct TodoDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date?
    let onSave: (Date?) -> Void
    @State private var selection: Date

    init(date: Date?, onSave: @escaping (Date?) -> Void) {
        self.date = date
        self.onSave = onSave
        _selection = State(initialValue: dayOnly(date ?? Date()))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DatePicker("日期", selection: $selection, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack(spacing: 12) {
                        Button("今天") { selection = dayOnly(Date()) }
                        Button("明天") {
                            selection = qddCalendar.date(byAdding: .day, value: 1, to: dayOnly(Date())) ?? selection
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(minHeight: 44)
                    if date != nil {
                        Button("清除日期", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.readablePrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark", role: todoConfirmationRole) {
                        onSave(dayOnly(selection))
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .presentationDetents([.height(540), .large])
        .presentationDragIndicator(.visible)
    }
}

/// Pool links carry the same screenshot in the picker, draft, list and details.
/// Video links retain the compact symbol-and-title treatment.
private struct TodoLinkedContentLabel: View {
    let link: TodoContentLink
    let records: [AdRecord]
    var compact = false

    private var record: AdRecord? { link.resolvedRecords(in: records).first }
    private var title: String {
        guard let record else { return "\(link.fallbackTitle) · 原内容不可用" }
        return link.kind == .video ? record.videoTitle.nonEmptyOr(link.fallbackTitle) : record.titleText
    }

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            if link.kind == .pool, let record {
                TodoLinkedPoolThumbnail(record: record)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: link.kind == .video ? "video" : "tray")
                    .frame(width: compact ? 16 : nil)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .font(compact ? .footnote : .subheadline)
        .foregroundStyle(AppTheme.readablePrimary)
        .frame(minHeight: compact ? 22 : 44, alignment: .leading)
    }
}

private struct TodoLinkDestinationSelection: Identifiable {
    let id = UUID()
    let link: TodoContentLink
    let spaceID: NSManagedObjectID
}

// Keep the app's iOS 18 support while adopting the system's colored confirmation
// and compact toolbar search on iOS 26 and later.
private var todoConfirmationRole: ButtonRole? {
    if #available(iOS 26.0, *) { return .confirm }
    return nil
}

private struct ListPressHoldObserver: UIViewRepresentable {
    @Binding var isHolding: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isHolding: $isHolding) }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.isHolding = $isHolding
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let coordinator, window != nil else { return }
            var ancestor: UIView? = superview
            var listView: UIScrollView?
            while let current = ancestor {
                if let scroll = current.subviews.compactMap({ $0 as? UICollectionView ?? $0 as? UITableView as UIScrollView? }).first {
                    listView = scroll
                    break
                }
                ancestor = current.superview
            }
            guard let listView, coordinator.attachedView !== listView else { return }
            coordinator.attach(to: listView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isHolding: Binding<Bool>
        weak var attachedView: UIView?
        private let recognizer = UILongPressGestureRecognizer()

        init(isHolding: Binding<Bool>) {
            self.isHolding = isHolding
            super.init()
            recognizer.minimumPressDuration = 0.2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        func attach(to view: UIView) {
            attachedView?.removeGestureRecognizer(recognizer)
            view.addGestureRecognizer(recognizer)
            attachedView = view
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                if !isHolding.wrappedValue { isHolding.wrappedValue = true }
            case .ended, .cancelled, .failed:
                if isHolding.wrappedValue { isHolding.wrappedValue = false }
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
