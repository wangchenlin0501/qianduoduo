//
//  EditorViews.swift
//  钱多多
//

import CoreData
import Combine
import PhotosUI
import SwiftUI
import UIKit

struct PoolRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    let record: AdRecord?
    let poolMonth: Date?

    @State private var brandName: String
    @State private var contactWeChat: String
    @State private var category: AdCategory
    @State private var partnership: PartnershipType
    @State private var isLookRandom: Bool
    @State private var lookNumber: Int
    @State private var adFee: Double
    @State private var hasArrived: Bool
    @State private var arrivalDate: Date
    @State private var paymentNote: String
    @State private var selectedPoolMonth: Date
    @State private var photoData: Data?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var selectedScheduleID: String?

    init(record: AdRecord? = nil, poolMonth: Date? = nil) {
        self.record = record
        self.poolMonth = poolMonth
        _brandName = State(initialValue: record?.brandName ?? "")
        _contactWeChat = State(initialValue: record?.contactWeChat ?? "")
        _category = State(initialValue: record?.categoryValue ?? .clothing)
        _partnership = State(initialValue: record?.partnershipValue ?? .consignment)
        _isLookRandom = State(initialValue: record == nil || (record?.lookNumber ?? 0) <= 0)
        _lookNumber = State(initialValue: max(Int(record?.lookNumber ?? 1), 1))
        _adFee = State(initialValue: record?.adFee ?? 0)
        _hasArrived = State(initialValue: record?.arrivalDate != nil)
        _arrivalDate = State(initialValue: record?.arrivalDate ?? Date())
        _paymentNote = State(initialValue: record?.paymentNote ?? "")
        _selectedPoolMonth = State(initialValue: monthStart(record?.createdAt ?? poolMonth ?? Date()))
        _photoData = State(initialValue: record?.photoData)
        if let record, record.isAssignedToVideo {
            _selectedScheduleID = State(initialValue: scheduleTargetID(name: record.videoTitle.nonEmptyOr("未命名视频"), date: record.publishDate))
        } else {
            _selectedScheduleID = State(initialValue: nil)
        }
    }

    private var scheduleTargets: [ScheduleTarget] {
        let currentID = record?.objectID
        let existingTargetID: String? = record.flatMap { record in
            guard record.isAssignedToVideo else { return nil }
            return scheduleTargetID(
                name: record.videoTitle.nonEmptyOr("未命名视频"),
                date: record.publishDate
            )
        }

        return makeVideoGroups(from: Array(allRecords))
            .filter { group in
                let targetID = scheduleTargetID(name: group.name, date: group.date)
                let monthDate = group.monthDate ?? group.createdSortDate
                return targetID == existingTargetID
                    || qddCalendar.isDate(
                        monthDate,
                        equalTo: selectedPoolMonth,
                        toGranularity: .month
                    )
            }
            .map { group in
                let count = group.records.filter { currentID == nil || $0.objectID != currentID }.count
                return ScheduleTarget(
                    id: scheduleTargetID(name: group.name, date: group.date),
                    name: group.name,
                    date: group.date,
                    order: group.order,
                    recordCount: count
                )
            }
    }

    private var selectedScheduleTarget: ScheduleTarget? {
        guard let selectedScheduleID else { return nil }
        return scheduleTargets.first { $0.id == selectedScheduleID }
    }

    var body: some View {
        EditorFormContainer {
            EditorCardSection("衣服截图", symbol: "photo.fill") {
                EditorCardRow(showsDivider: false) {
                    PhotoPickerRow(photoData: $photoData, photoPickerItem: $photoPickerItem)
                }
            }

            EditorCardSection("待拍摄广告", symbol: "square.and.pencil") {
                EditorCardRow {
                    TextField("品牌", text: $brandName)
                        .textInputAutocapitalization(.never)
                }
                EditorCardRow {
                    TextField("对接人微信", text: $contactWeChat)
                        .textInputAutocapitalization(.never)
                }
                EditorCardRow {
                    Picker("品类", selection: $category) {
                        ForEach(AdCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                }
                EditorCardRow {
                    Picker("合作方式", selection: $partnership) {
                        ForEach(PartnershipType.allCases) { type in
                            Label(type.rawValue, systemImage: type.symbolName)
                                .foregroundStyle(type.tint)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(partnership.tint)
                }
                EditorCardRow {
                    Picker("Look", selection: $isLookRandom) {
                        Text("随机").tag(true)
                        Text("指定").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                if !isLookRandom {
                    EditorCardRow {
                        Stepper(value: $lookNumber, in: 1...50) {
                            Text("Look \(lookNumber)")
                        }
                    }
                }
                EditorCardRow(showsDivider: false) {
                    AmountField(amount: $adFee, title: partnership == .exchange ? "置换无需报价" : "报价", placeholder: "报价")
                        .disabled(partnership == .exchange)
                }
            }

            EditorCardSection("备注", symbol: "note.text") {
                EditorCardRow(showsDivider: false) {
                    TextField("备注", text: $paymentNote, axis: .vertical)
                        .lineLimit(3...5)
                }
            }

            EditorCardSection("状态", symbol: "checkmark.circle.fill") {
                EditorCardRow(showsDivider: false) {
                    StatusButton(
                        inactiveTitle: "未到货",
                        activeTitle: "已到货",
                        isSelected: hasArrived,
                        date: arrivalDate,
                        dateLabel: "到货日期",
                        hint: "到货后点一下记录今天",
                        symbolName: "shippingbox.fill",
                        tint: AppTheme.primary
                    ) {
                        hasArrived.toggle()
                        if hasArrived {
                            arrivalDate = dayOnly(Date())
                        }
                    }
                }
            }

            EditorCardSection("池子月份", symbol: "calendar", showsTitle: false) {
                EditorCardRow(showsDivider: false) {
                    PoolMonthSelectorRow(selectedMonth: $selectedPoolMonth)
                }
            }

            EditorCardSection("排期", symbol: "calendar.badge.clock") {
                EditorCardRow(showsDivider: scheduleTargets.isEmpty || selectedScheduleTarget != nil) {
                    Picker("排期到视频", selection: $selectedScheduleID) {
                        Text("不排期").tag(Optional<String>.none)
                        ForEach(scheduleTargets) { target in
                            Text(target.menuTitle).tag(Optional(target.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                if let selectedScheduleTarget {
                    EditorCardRow(showsDivider: false) {
                        HStack {
                            Label(selectedScheduleTarget.title, systemImage: "calendar")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer()
                            Text(selectedScheduleTarget.date.map { shortDateText($0) } ?? "待定")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if scheduleTargets.isEmpty {
                    EditorCardRow(showsDivider: false) {
                        Label("暂无可排期的视频", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(record == nil ? "新增池子记录" : "编辑池子记录")
        .softPageBackground()
        .onChange(of: partnership) { _, newValue in
            if !newValue.needsPayment {
                adFee = 0
            }
        }
        .onChange(of: selectedPoolMonth) { _, _ in
            guard let selectedScheduleID,
                  !scheduleTargets.contains(where: { $0.id == selectedScheduleID }) else {
                return
            }
            self.selectedScheduleID = nil
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
            }
        }
    }

    private func save() {
        let target = record ?? AdRecord(context: viewContext)
        if record == nil || target.syncSpace == nil {
            PersistenceController.shared.prepareNewRecord(target, in: viewContext)
        }

        if target.id == nil {
            target.id = UUID()
        }
        target.createdAt = monthStart(selectedPoolMonth)
        if target.poolOrder <= 0 {
            target.poolOrder = Date().timeIntervalSinceReferenceDate
        }

        target.brandName = cleaned(brandName).nonEmptyOr("未填写品牌")
        target.contactWeChat = cleaned(contactWeChat)
        target.categoryValue = category
        target.partnershipValue = partnership
        target.lookNumber = isLookRandom ? 0 : Int16(clamping: lookNumber)
        target.adFee = partnership.needsPayment ? max(adFee, 0) : 0
        target.arrivalDate = hasArrived ? dayOnly(arrivalDate) : nil
        target.paymentNote = cleaned(paymentNote)
        target.photoData = photoData
        if let selectedScheduleTarget {
            target.videoTitle = selectedScheduleTarget.name
            target.publishDate = selectedScheduleTarget.date.map(dayOnly)
            target.videoOrder = selectedScheduleTarget.order
        } else {
            target.videoTitle = nil
            target.publishDate = nil
            target.videoOrder = 0
        }
        target.publishedDate = nil
        target.commentReminderID = nil
        target.brandCommentedAt = nil
        target.paidDate = nil
        target.paymentAccount = nil
        target.paidAmount = 0
        target.statusValue = .unpaid
        target.clothingName = nil
        target.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            PersistenceController.shared.shareOwnedRecordIfNeeded(target)
            notifyRecordsChanged()
            dismiss()
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved CoreData error \(nsError), \(nsError.userInfo)")
        }
    }

    private func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AdRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let record: AdRecord?

    @State private var brandName: String
    @State private var contactWeChat: String
    @State private var category: AdCategory
    @State private var partnership: PartnershipType
    @State private var lookNumber: Int
    @State private var adFee: Double
    @State private var hasArrived: Bool
    @State private var arrivalDate: Date
    @State private var isPaid: Bool
    @State private var paidDate: Date
    @State private var paymentMethod: PaymentMethod
    @State private var paymentNote: String
    @State private var photoData: Data?
    @State private var photoPickerItem: PhotosPickerItem?

    init(record: AdRecord? = nil) {
        self.record = record
        _brandName = State(initialValue: record?.brandName ?? "")
        _contactWeChat = State(initialValue: record?.contactWeChat ?? "")
        _category = State(initialValue: record?.categoryValue ?? .clothing)
        _partnership = State(initialValue: record?.partnershipValue ?? .consignment)
        _lookNumber = State(initialValue: max(Int(record?.lookNumber ?? 1), 1))
        _adFee = State(initialValue: record?.adFee ?? 0)
        _hasArrived = State(initialValue: record?.arrivalDate != nil)
        _arrivalDate = State(initialValue: record?.arrivalDate ?? Date())
        _isPaid = State(initialValue: record?.statusValue == .paid)
        _paidDate = State(initialValue: record?.paidDate ?? Date())
        _paymentMethod = State(initialValue: record?.paymentMethodValue ?? .weChat)
        _paymentNote = State(initialValue: record?.paymentNote ?? "")
        _photoData = State(initialValue: record?.photoData)
    }

    var body: some View {
        EditorFormContainer {
            if canEditPayment {
                EditorCardSection("打款", symbol: "yensign.circle.fill") {
                    EditorCardRow(showsDivider: isPaid) {
                        StatusButton(
                            inactiveTitle: "未打款",
                            activeTitle: "已打款",
                            isSelected: isPaid,
                            date: paidDate,
                            dateLabel: "打款日期",
                            hint: "确认打款后点击记录",
                            symbolName: "yensign.circle.fill",
                            tint: .green
                        ) {
                            isPaid.toggle()
                            if isPaid {
                                paidDate = dayOnly(Date())
                            }
                        }
                    }

                    if isPaid {
                        EditorCardRow(showsDivider: false) {
                            Picker("打款方式", selection: $paymentMethod) {
                                ForEach(PaymentMethod.allCases) { method in
                                    Label(method.rawValue, systemImage: method.symbolName).tag(method)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }

            EditorCardSection("衣服截图", symbol: "photo.fill") {
                EditorCardRow(showsDivider: false) {
                    PhotoPickerRow(photoData: $photoData, photoPickerItem: $photoPickerItem)
                }
            }

            EditorCardSection("广告", symbol: "megaphone.fill") {
                EditorCardRow {
                    TextField("品牌", text: $brandName)
                        .textInputAutocapitalization(.never)
                }
                EditorCardRow {
                    TextField("对接人微信", text: $contactWeChat)
                        .textInputAutocapitalization(.never)
                }
                EditorCardRow {
                    Picker("品类", selection: $category) {
                        ForEach(AdCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                }
                EditorCardRow {
                    Picker("合作方式", selection: $partnership) {
                        ForEach(PartnershipType.allCases) { type in
                            Label(type.rawValue, systemImage: type.symbolName)
                                .foregroundStyle(type.tint)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(partnership.tint)
                }
                EditorCardRow {
                    Stepper(value: $lookNumber, in: 1...50) {
                        Text("Look \(lookNumber)")
                    }
                }
                EditorCardRow(showsDivider: false) {
                    AmountField(amount: $adFee, title: partnership == .exchange ? "置换无需报价" : "广告费", placeholder: "报价")
                        .disabled(partnership == .exchange)
                }
            }

            EditorCardSection("视频", symbol: "play.rectangle.fill") {
                EditorCardRow {
                    InfoRow(title: "视频名称", value: record?.videoTitle.nonEmptyOr("未命名视频") ?? "未命名视频")
                }
                EditorCardRow {
                    InfoRow(title: "视频日期", value: shortDateText(record?.publishDate))
                }
                EditorCardRow(showsDivider: false) {
                    InfoRow(title: "发布状态", value: record?.publishedDate.map { "已发布 " + shortDateText($0) } ?? "未发布")
                }
            }

            EditorCardSection("备注", symbol: "note.text") {
                EditorCardRow(showsDivider: false) {
                    TextField("备注", text: $paymentNote, axis: .vertical)
                        .lineLimit(3...5)
                }
            }
        }
        .navigationTitle("编辑记录")
        .softPageBackground()
        .onChange(of: partnership) { _, newValue in
            if !newValue.needsPayment {
                adFee = 0
                isPaid = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
            }
        }
    }

    private var canEditPayment: Bool {
        partnership.needsPayment && (record?.publishedDate != nil || record?.statusValue == .paid)
    }

    private func save() {
        guard let target = record else {
            dismiss()
            return
        }
        let normalizedAdFee = max(adFee, 0)

        if target.id == nil {
            target.id = UUID()
        }
        if target.createdAt == nil {
            target.createdAt = Date()
        }

        target.brandName = cleaned(brandName).nonEmptyOr("未填写品牌")
        target.contactWeChat = cleaned(contactWeChat)
        target.categoryValue = category
        target.partnershipValue = partnership
        target.lookNumber = Int16(clamping: lookNumber)
        target.adFee = partnership.needsPayment ? normalizedAdFee : 0
        target.arrivalDate = hasArrived ? dayOnly(arrivalDate) : nil
        target.photoData = photoData
        if canEditPayment {
            target.paidAmount = isPaid ? normalizedAdFee : 0
            target.statusValue = isPaid ? .paid : .unpaid
            target.paidDate = isPaid ? dayOnly(paidDate) : nil
            target.paymentAccount = isPaid ? paymentMethod.rawValue : nil
        } else {
            target.paidAmount = 0
            target.statusValue = .unpaid
            target.paidDate = nil
            target.paymentAccount = nil
        }
        target.paymentNote = cleaned(paymentNote)
        target.clothingName = nil
        target.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
            dismiss()
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved CoreData error \(nsError), \(nsError.userInfo)")
        }
    }

    private func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EditorFormContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, AppLayout.editorHorizontalInset)
            .padding(.top, 18)
            .padding(.bottom, 110)
        }
    }
}

struct EditorCardSection<Content: View>: View {
    let title: String
    let symbol: String
    let showsTitle: Bool
    private let content: Content

    init(
        _ title: String,
        symbol: String,
        showsTitle: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.showsTitle = showsTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showsTitle ? 10 : 0) {
            if showsTitle {
                AppCardTitle(title: title, symbol: symbol)
            }

            VStack(spacing: 0) {
                content
            }
        }
        .padding(AppLayout.cardContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurfaceBackground())
    }
}

struct EditorCardRow<Content: View>: View {
    var showsDivider = true
    private let content: Content

    init(showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)

            if showsDivider {
                Divider()
            }
        }
    }
}

struct PhotoPickerRow: View {
    @Binding var photoData: Data?
    @Binding var photoPickerItem: PhotosPickerItem?
    @State private var showFullScreen = false
    @State private var cropSessionID: UUID?
    @State private var cropImage: UIImage?
    @State private var cropLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Button {
                    showFullScreen = true
                } label: {
                    editorPhotoPreview(image: image)
                }
                .buttonStyle(.plain)
            } else {
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    emptyPhotoPicker
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label(photoData == nil ? "添加截图" : "更换截图", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)

                if photoData != nil {
                    Spacer()

                    Button(role: .destructive) {
                        photoData = nil
                        photoPickerItem = nil
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .fullScreenCover(isPresented: $showFullScreen) {
            PhotoFullScreenView(image: image)
        }
        .fullScreenCover(isPresented: cropSessionBinding) {
            if let cropImage {
                PhotoCropperView(image: cropImage) { croppedImage in
                    if let normalizedData = normalizedPhotoData(croppedImage) {
                        photoData = normalizedData
                    }
                    resetCropSession()
                } onCancel: {
                    resetCropSession()
                }
            } else {
                PhotoCropLoadingView {
                    resetCropSession()
                }
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            let sessionID = UUID()
            cropLoadTask?.cancel()
            cropSessionID = sessionID
            cropImage = nil

            cropLoadTask = Task {
                let pickedImage: UIImage?
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    pickedImage = await decodedPhotoImage(from: data)
                } else {
                    pickedImage = nil
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard cropSessionID == sessionID else { return }
                    if let pickedImage {
                        cropImage = pickedImage
                    } else {
                        resetCropSession()
                    }
                }
            }
        }
    }

    private var cropSessionBinding: Binding<Bool> {
        Binding {
            cropSessionID != nil
        } set: { isPresented in
            if !isPresented {
                resetCropSession()
            }
        }
    }

    private func resetCropSession() {
        cropLoadTask?.cancel()
        cropLoadTask = nil
        cropSessionID = nil
        cropImage = nil
        photoPickerItem = nil
    }

    private var image: UIImage? {
        PhotoImageCache.shared.image(from: photoData)
    }

    private var emptyPhotoPicker: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.primary)

            Text("添加截图")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 156)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func editorPhotoPreview(image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .aspectRatio(PhotoCropperView.cropAspectRatio, contentMode: .fit)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PhotoCropperView: View {
    static let cropAspectRatio: CGFloat = 1.0

    let image: UIImage
    let onUse: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var cropController = PhotoCropController()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("取消") {
                    onCancel()
                }

                Spacer()

                Text("裁切截图")
                    .font(.headline.weight(.semibold))

                Spacer()

                Button("使用") {
                    onUse(cropController.croppedImage() ?? image)
                }
                .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Spacer(minLength: 20)

            CropImageView(image: image, controller: cropController)
                .aspectRatio(Self.cropAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.82), lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)

            Text("拖动照片调整位置，双指缩放后再使用")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 28)
        .background(Color.black.ignoresSafeArea())
    }
}

struct PhotoCropLoadingView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("取消") {
                    onCancel()
                }
                .foregroundStyle(.white)

                Spacer()

                Text("裁切截图")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Color.clear
                    .frame(width: 36, height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Spacer()

            ProgressView()
                .controlSize(.large)
                .tint(.white)

            Text("正在准备照片")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text("照片比较大时这里会等一下，准备好后就能裁切")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
    }
}

final class PhotoCropController: ObservableObject {
    weak var cropView: CropImageContainerView?

    func croppedImage() -> UIImage? {
        cropView?.croppedImage()
    }
}

struct CropImageView: UIViewRepresentable {
    let image: UIImage
    @ObservedObject var controller: PhotoCropController

    func makeUIView(context: Context) -> CropImageContainerView {
        let view = CropImageContainerView()
        view.image = image
        controller.cropView = view
        return view
    }

    func updateUIView(_ uiView: CropImageContainerView, context: Context) {
        uiView.image = image
        if controller.cropView !== uiView {
            controller.cropView = uiView
        }
    }
}

final class CropImageContainerView: UIView, UIScrollViewDelegate {
    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            didConfigureImage = false
            scrollView.zoomScale = 1
            setNeedsLayout()
        }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var didConfigureImage = false
    private var configuredBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        scrollView.addSubview(imageView)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        configureImageFrameIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func croppedImage() -> UIImage? {
        guard
            let image,
            image.size.width > 0,
            image.size.height > 0,
            imageView.bounds.width > 0,
            imageView.bounds.height > 0,
            scrollView.bounds.width > 0,
            scrollView.bounds.height > 0
        else {
            return image
        }

        let zoomScale = max(scrollView.zoomScale, 0.0001)
        let visibleRect = CGRect(
            x: scrollView.contentOffset.x / zoomScale,
            y: scrollView.contentOffset.y / zoomScale,
            width: scrollView.bounds.width / zoomScale,
            height: scrollView.bounds.height / zoomScale
        )

        let imageScaleX = image.size.width / imageView.bounds.width
        let imageScaleY = image.size.height / imageView.bounds.height
        let cropRect = visibleRect
            .applying(CGAffineTransform(scaleX: imageScaleX, y: imageScaleY))
            .intersection(CGRect(origin: .zero, size: image.size))

        guard cropRect.width > 1, cropRect.height > 1 else { return image }

        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            image.draw(
                in: CGRect(
                    x: -cropRect.origin.x,
                    y: -cropRect.origin.y,
                    width: image.size.width,
                    height: image.size.height
                )
            )
        }
    }

    private func configureImageFrameIfNeeded() {
        guard
            let image,
            bounds.width > 0,
            bounds.height > 0,
            image.size.width > 0,
            image.size.height > 0,
            !didConfigureImage || configuredBoundsSize != bounds.size
        else {
            return
        }

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fillScale = max(widthScale, heightScale)
        let imageSize = CGSize(width: image.size.width * fillScale, height: image.size.height * fillScale)

        scrollView.zoomScale = 1
        imageView.bounds = CGRect(origin: .zero, size: imageSize)
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        scrollView.contentSize = imageSize
        scrollView.contentOffset = CGPoint(
            x: max((imageSize.width - bounds.width) / 2, 0),
            y: max((imageSize.height - bounds.height) / 2, 0)
        )

        configuredBoundsSize = bounds.size
        didConfigureImage = true
    }
}

struct AmountField: View {
    @Binding var amount: Double
    let title: String
    var placeholder: String = ""

    @State private var textValue: String = ""
    @State private var didInit = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "yensign.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 34)
            TextField(placeholder.isEmpty ? title : placeholder, text: $textValue)
                .keyboardType(.decimalPad)
                .font(.body)
                .onChange(of: textValue) { _, newValue in
                    let cleaned = newValue.replacingOccurrences(of: "，", with: ".")
                    if let parsed = Double(cleaned) {
                        amount = parsed
                    } else if cleaned.isEmpty {
                        amount = 0
                    }
                }
        }
        .padding(.vertical, 4)
        .accessibilityLabel(title)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            textValue = amount > 0 ? String(format: "%g", amount) : ""
        }
    }
}

struct PoolMonthSelectorRow: View {
    @Binding var selectedMonth: Date
    @State private var showingMonthPicker = false

    var body: some View {
        Button {
            showingMonthPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.primary.opacity(0.12), in: Circle())

                Text("池子月份")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Text(monthTitle(selectedMonth))
                        .font(.subheadline.weight(.bold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(AppTheme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AppTheme.primary.opacity(0.1), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingMonthPicker) {
            NavigationStack {
                MonthPickerView(selectedMonth: $selectedMonth)
            }
            .presentationDetents([.medium])
        }
    }
}

struct RecordThumbnail: View {
    let photoData: Data?
    let size: CGFloat

    @State private var showFullScreen = false

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .onTapGesture {
                        showFullScreen = true
                    }
            } else {
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            PhotoFullScreenView(image: image)
        }
    }

    private var image: UIImage? {
        PhotoImageCache.shared.image(from: photoData)
    }
}

struct PhotoFullScreenView: View {
    let image: UIImage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomablePhotoView(image: image) {
                    dismiss()
                }
                .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomablePhotoContainerView {
        let view = ZoomablePhotoContainerView()
        view.image = image
        view.onDismiss = onDismiss
        return view
    }

    func updateUIView(_ uiView: ZoomablePhotoContainerView, context: Context) {
        uiView.image = image
        uiView.onDismiss = onDismiss
    }
}

final class ZoomablePhotoContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            scrollView.zoomScale = 1
            setNeedsLayout()
        }
    }

    var onDismiss: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        addSubview(scrollView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)

        let dismissPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPanGesture.minimumNumberOfTouches = 1
        dismissPanGesture.maximumNumberOfTouches = 1
        dismissPanGesture.cancelsTouchesInView = false
        dismissPanGesture.delegate = self
        addGestureRecognizer(dismissPanGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateImageFrameIfNeeded()
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap() {
        onDismiss?()
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: self)
        let distance = hypot(translation.x, translation.y)
        if distance > 28 {
            onDismiss?()
        }
    }

    private func updateImageFrameIfNeeded() {
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        let availableSize = bounds.insetBy(dx: 16, dy: 16).size
        guard availableSize.width > 0, availableSize.height > 0 else { return }

        let widthScale = availableSize.width / image.size.width
        let heightScale = availableSize.height / image.size.height
        let fitScale = min(widthScale, heightScale)
        let fitSize = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)

        if scrollView.zoomScale == 1, imageView.bounds.size != fitSize {
            imageView.bounds = CGRect(origin: .zero, size: fitSize)
            imageView.frame = CGRect(origin: .zero, size: fitSize)
            scrollView.contentSize = fitSize
        }
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }
}

struct WorkflowBadge: View {
    let workflow: AdWorkflow

    var body: some View {
        Label(workflow.rawValue, systemImage: workflow.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(workflow.tint)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct PaymentPill: View {
    @ObservedObject var record: AdRecord

    var body: some View {
        let status = record.statusValue
        let tint = record.needsPayment ? status.tint : PartnershipType.exchange.tint
        HStack(spacing: 5) {
            Image(systemName: record.needsPayment ? status.symbolName : PartnershipType.exchange.symbolName)
            Text(record.needsPayment ? (status == .paid ? "已结清" : "待结款") : "无需打款")
        }
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

struct StatusButton: View {
    let inactiveTitle: String
    let activeTitle: String
    let isSelected: Bool
    let date: Date?
    let dateLabel: String
    let hint: String
    let symbolName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? tint : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isSelected ? activeTitle : inactiveTitle)
                        .foregroundStyle(.primary)
                    Text(isSelected ? "\(dateLabel) \(shortDateText(date))" : hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: symbolName)
                    .foregroundStyle(isSelected ? tint : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
