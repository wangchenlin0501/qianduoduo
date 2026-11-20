//
//  AIAssistantView.swift
//  钱多多
//

import Combine
import CoreData
import PDFKit
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AIAssistantSession: ObservableObject {
    struct Bubble: Identifiable {
        enum Role { case user, assistant, notice, card }
        let id = UUID()
        let role: Role
        let text: String
        var images: [UIImage] = []
        var card: AIRecordCard?
        var undoID: UUID?
    }

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var pending: AIPendingAction?
    @Published private(set) var lastUndo: AIUndoToken?
    @Published private(set) var isBusy = false

    private let toolbox: AIAssistantToolbox
    private let context: NSManagedObjectContext
    var pageName: String
    private var history: [[String: Any]]

    init(context: NSManagedObjectContext, pageName: String) {
        toolbox = AIAssistantToolbox(context: context)
        self.context = context
        self.pageName = pageName
        history = [["role": "system", "content": Self.systemPrompt(pageName: pageName, memory: [])]]
    }

    func send(_ text: String, images: [UIImage] = [], displayText: String? = nil, fileNames: [String] = []) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, !isBusy else { return }
        let client: AIAssistantClient
        do {
            client = try AIAssistantClient.current(context: context)
        } catch {
            bubbles.append(Bubble(role: .notice, text: error.localizedDescription))
            return
        }

        if let pending {
            history.append(["role": "assistant", "content": "（用户没有处理确认卡片「\(pending.title)」，已作废）"])
            self.pending = nil
        }
        let shown = ([displayText ?? text] + fileNames.map { "📎 \($0)" }).filter { !$0.isEmpty }.joined(separator: "\n")
        bubbles.append(Bubble(role: .user, text: shown, images: images))
        history[0] = ["role": "system", "content": Self.systemPrompt(pageName: pageName, memory: AIMemoryStore.load(in: context))]
        if !images.isEmpty { toolbox.latestImages = images }
        if images.isEmpty {
            history.append(["role": "user", "content": text])
        } else {
            var parts: [[String: Any]] = [[
                "type": "text",
                "text": text.isEmpty ? "（用户发来图片，没有附文字）" : text
            ]]
            for image in images {
                guard let url = Self.dataURL(for: image) else { continue }
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            history.append(["role": "user", "content": parts])
        }
        isBusy = true
        defer { isBusy = false }

        do {
            for _ in 0..<8 {
                let body = try JSONSerialization.data(withJSONObject: [
                    "model": client.model,
                    "messages": history,
                    "tools": AIAssistantToolbox.definitions + AIAssistantClient.webDefinitions,
                    "temperature": 0.3
                ] as [String: Any])
                let data = try await client.send(body: body)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any] else {
                    throw AIAssistantError.badResponse
                }
                let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let calls = message["tool_calls"] as? [[String: Any]] ?? []

                guard !calls.isEmpty else {
                    history.append(["role": "assistant", "content": content])
                    bubbles.append(Bubble(role: .assistant, text: content.isEmpty ? "（没有回复内容）" : content))
                    return
                }

                history.append(["role": "assistant", "content": content, "tool_calls": calls])
                if !content.isEmpty { bubbles.append(Bubble(role: .assistant, text: content)) }
                for call in calls {
                    let callID = call["id"] as? String ?? ""
                    let function = call["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let arguments = function["arguments"] as? String ?? "{}"
                    if name == "web_search" || name == "fetch_page" {
                        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
                        let label = name == "web_search" ? "搜索：\(args["query"] as? String ?? "")" : "读取网页"
                        bubbles.append(Bubble(role: .notice, text: label))
                        let result = await client.runWebTool(name: name, arguments: arguments)
                        history.append(["role": "tool", "tool_call_id": callID, "content": result])
                        continue
                    }
                    let result: String
                    switch toolbox.run(name: name, arguments: arguments) {
                    case let .result(text):
                        result = text
                    case let .card(card, json):
                        bubbles.append(Bubble(role: .card, text: "", card: card))
                        result = json + "\n（已用卡片把这些记录展示给用户，正文不要再逐条列出，只做概括和建议。）"
                    case let .proposal(action):
                        if pending == nil {
                            pending = action
                            result = "已向用户显示确认卡片「\(action.title)」，尚未执行。用一句话请用户核对并确认，不要说已完成。"
                        } else {
                            result = "一次只能确认一项，这一项没有提交。请在用户处理完当前卡片后再提。"
                        }
                    }
                    history.append(["role": "tool", "tool_call_id": callID, "content": result])
                }
            }
            bubbles.append(Bubble(role: .notice, text: "这次步骤太多，没能完成，换个说法再试试。"))
        } catch {
            bubbles.append(Bubble(role: .notice, text: error.localizedDescription))
        }
    }

    func confirm() {
        guard let action = pending else { return }
        pending = nil
        do {
            let token = try action.perform()
            lastUndo = token
            bubbles.append(Bubble(role: .notice, text: "已完成：\(token.summary)", undoID: token.id))
            history.append(["role": "assistant", "content": "（用户已确认，已执行：\(token.summary)）"])
        } catch {
            bubbles.append(Bubble(role: .notice, text: "执行失败：\(error.localizedDescription)"))
        }
    }

    /// Video built by the user from a record card (selection and order chosen by hand).
    func proposeVideo(refs: [String], title: String, date: Date?) {
        guard !isBusy, !refs.isEmpty else { return }
        if let pending {
            history.append(["role": "assistant", "content": "（用户没有处理确认卡片「\(pending.title)」，已作废）"])
            self.pending = nil
        }
        var args: [String: Any] = ["title": title, "ids": refs, "keep_order": true]
        if let date {
            let formatter = DateFormatter()
            formatter.calendar = qddCalendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            args["date"] = formatter.string(from: date)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args) else { return }
        switch toolbox.run(name: "propose_schedule_video", arguments: String(decoding: data, as: UTF8.self)) {
        case let .proposal(action):
            pending = action
            history.append(["role": "assistant", "content": "（用户在卡片里手动挑了 \(refs.count) 条（\(refs.joined(separator: ", "))），准备排进视频「\(title)」，等待确认）"])
        case let .result(text):
            let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? String
            bubbles.append(Bubble(role: .notice, text: message ?? "没能生成视频"))
        case .card:
            break
        }
    }

    func cancel() {
        guard let action = pending else { return }
        pending = nil
        bubbles.append(Bubble(role: .notice, text: "已取消：\(action.title)"))
        history.append(["role": "assistant", "content": "（用户取消了：\(action.title)）"])
    }

    func undo() {
        guard let token = lastUndo else { return }
        lastUndo = nil
        do {
            try token.undo()
            bubbles.append(Bubble(role: .notice, text: "已撤销：\(token.summary)"))
            history.append(["role": "assistant", "content": "（用户已撤销：\(token.summary)）"])
        } catch {
            bubbles.append(Bubble(role: .notice, text: "撤销失败：\(error.localizedDescription)"))
        }
    }

    private static func dataURL(for image: UIImage) -> String? {
        let maxSide: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private static func systemPrompt(pageName: String, memory: [AIMemoryItem]) -> String {
        let memoryText = memory.isEmpty
            ? "（暂无）"
            : memory.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        return """
        你是“钱多多”，是这个记账 App 里的助手，帮用户管理品牌合作、视频排期、回款和待办。
        App 由两个人共用，记忆也是两人共享。
        今天是 \(AIAssistantToolbox.dayString(Date()))（北京时间）。用户当前在“\(pageName)”页面。

        你记得的事（方括号里是 id，忘记时用 propose_forget）。这些是用户定下的规则，每次调用工具前都要对照遵守：
        \(memoryText)

        说话风格：
        - 像熟悉情况的朋友一样，用自己的话概括，不要把工具返回的字段逐条照搬。
        - 尽量短：通常两三句话。
        - 不用颜文字和表情符号。
        - 排版要好读：先一句结论；内容分几块时每块用“## 小标题”，标题末尾可以加一个 {{标签}}（如 {{12月前}}、{{急}}）会显示成彩色徽标；关键数字或结论用 **加粗**；并列要点用 - 列表。短回答不用标题。
        - 涉及 2 条以上记录（推荐、对比、清单）时，一定先调用 show_records 用带照片的卡片展示，可按品类等分组多次调用；正文只写结论、理由和要问的问题，不再逐条列品牌金额。unpaid_summary 会自动出卡片。
        - 有必要时给一条具体建议（例如先催哪一家、什么时候催）；信息不够或有歧义时直接反问一句。
        - 回款到账、全部结清时可以简单恭喜一句。
        - 金额、日期、品牌名必须准确。金额单位为人民币。

        规则：
        - 所有数字以工具返回为准，不自己心算或编造；查不到就直说。
        - 多条匹配时反问用户是哪一条，不擅自选择。
        - 你能做：新增/修改/删除记录（含合作方式、品类、到货、到货日期、发布日期、款式名、对接人、照片），排视频、移回池子、标记回款，新建/修改/完成/删除待办，记住/忘记。用户说“到货了”“发了”就直接用 propose_update_ad 改对应字段。用户明确要求打开某个页面时用 navigate_to。发布满 100 天仍未回款的记录视为放弃：unpaid_summary、find_ads 默认已排除，不要主动提、不要逐条列出，也不要催款；只有用户追问时才把 include_abandoned 设为 true 查询。用户要催款时，先 find_ads/unpaid_summary 选好记录，再用 propose_chase_payment 给出话术。
        - 这些写入都通过 propose_ 开头的工具，只会弹出确认卡片；用户确认前不要说已完成。确认后可撤销。
        - 工具的 id 只能使用查询结果里返回的值。
        - “这个月”指谈下合作的月份（deal_month）。未回款要分开说：已发布未回款（可以催款）和未发布（还没到催款时候）。
        - 置换不计入未回款；送拍计入，但要标明“送拍”。
        - 催款话术只生成文本，由用户自己发送。
        - 可以联网：需要 App 外的信息（品牌背景、报价行情、新闻、平台规则）时用 web_search，必要时 fetch_page 读原文；用户发来链接时直接 fetch_page。用到网上信息时，末尾用 [站点名](链接) 附 1-3 个来源。App 里的数据只用本地工具查，不要搜。
        - 不支持备份导入、共享设置；被问到时说明做不到。
        - 用户发来合作聊天截图时，提取品牌、金额、合作方式、look 号、对接人和月份，拿不准的先问；信息够了就用 propose_create_ad 入池。月份：截图有明确标注的按标注月份，否则用本月。
        - 入池时：用户没明确说 look 号就不传 look（记录为随机，不要自己填 1）；对接人的微信名/微信号填 wechat，不要写进 note；照片用 photo_index 选衣服/产品图（不选聊天截图），后续追问修改时也要带上 photo_index。
        - 排视频：用户给出视频标题或想法时，先用 find_ads（stage=待拍摄）查池子，挑合适的几条，用 show_records 卡片展示推荐组合（标题如“推荐：xx 视频”），再用一两句说明理由；用户同意后用 propose_schedule_video。用户也可以直接在卡片里点选、拖动排序后自己生成视频，可顺带提一句。
          挑选优先级：① 同一条视频只放同一类东西（全是衣服、全是裤子、全是鞋子等，按 category 判断），不混搭；只有“购物分享”这类视频才可以混放配饰和其他杂项。② 贴合视频标题的主题。③ 到货情况只作参考：可以顺带提一句哪条还没到，但不要因为没到货就排除，也不要按到货分组。
        - 发现值得长期记住的习惯、偏好或信息（如某品牌的对接人、付款习惯）时，先问一句要不要记住，用户同意后用 propose_remember。

        术语表：寄 = 寄拍；坑 N = 第 N 个 look（如坑三 = 第 3 个 look）；🈴 忽略。不确定的说法先问。
        """
    }
}

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AIAssistantSession
    @State private var draft = ""
    @State private var attachments: [AIAttachment] = []
    @State private var showingCamera = false
    @State private var showingPhotos = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showingFiles = false
    @State private var showingAddMenu = false
    @State private var dragOffset: CGFloat = 0
    @FocusState private var inputFocused: Bool

    private let maxAttachments = 4
    private let suggestions: [(String, String)] = [
        ("yensign.circle", "这个月还有多少钱没拿到？"),
        ("bell.badge", "现在该跟谁催款？"),
        ("checklist", "还有哪些待办没做？")
    ]

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !session.isBusy
    }

    var body: some View {
        NavigationStack {
            messages
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !showingCamera { composer }
                }
                .overlay {
                    if showingAddMenu {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { showingAddMenu = false } }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if showingAddMenu {
                        addMenu
                            .padding(.leading, 12)
                            .padding(.bottom, 64)
                            .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color(.systemBackground), Color(.systemBackground).opacity(0.85), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    )
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭")
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if showingCamera {
                AIAssistantCameraCard(
                    onCapture: { image in
                        addAttachment(image)
                    },
                    onClose: closeCamera,
                    captured: cameraShots,
                    canCaptureMore: attachments.count < maxAttachments
                )
                .containerRelativeFrame(.vertical) { height, _ in height * 0.64 }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.12), value: showingCamera)
        .background(Color(.systemBackground).ignoresSafeArea())
        .offset(x: dragOffset)
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(edgeSwipe)
        }
        .fileImporter(
            isPresented: $showingFiles,
            allowedContentTypes: [.image, .pdf, .plainText, .commaSeparatedText, .json],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            for url in urls { importFile(url) }
        }
        .photosPicker(
            isPresented: $showingPhotos,
            selection: $pickedItems,
            maxSelectionCount: max(maxAttachments - attachments.count, 1),
            matching: .images
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            pickedItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        addAttachment(image)
                    }
                }
            }
        }
    }

    // MARK: - Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.bubbles.isEmpty {
                        intro
                    }
                    ForEach(session.bubbles) { bubble in
                        bubbleView(bubble)
                    }
                    if session.isBusy {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                    if let action = session.pending {
                        confirmCard(action)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.bubbles.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.pending?.id) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(suggestions, id: \.1) { icon, text in
                Button {
                    send(text: text, attachments: [])
                } label: {
                    Label(text, systemImage: icon)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func bubbleView(_ bubble: AIAssistantSession.Bubble) -> some View {
        switch bubble.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !bubble.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(bubble.images.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                if !bubble.text.isEmpty {
                    Text(bubble.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case .assistant:
            AIMarkdownText(text: bubble.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .card:
            if let card = bubble.card {
                AIRecordCardView(card: card, isBusy: session.isBusy) { refs, title, date in
                    session.proposeVideo(refs: refs, title: title, date: date)
                }
            }
        case .notice:
            VStack(spacing: 8) {
                Text(bubble.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let undoID = bubble.undoID, session.lastUndo?.id == undoID, !session.isBusy {
                    Button {
                        session.undo()
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func confirmCard(_ action: AIPendingAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(action.title, systemImage: "checkmark.shield")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(action.lines, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                    }
                    if let box = action.note {
                        AINoteField(box: box)
                    }
                }
                Spacer(minLength: 0)
                if let image = action.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            HStack(spacing: 12) {
                Button("取消") { session.cancel() }
                    .buttonStyle(.bordered)
                Button(action.confirmLabel ?? "确认") { session.confirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(action.isDestructive ? .red : AppTheme.primary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.primary.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            attachmentThumb(attachment)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }

            HStack(alignment: .bottom, spacing: 4) {
                Button {
                    inputFocused = false
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) { showingAddMenu.toggle() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(showingAddMenu ? 45 : 0))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(attachments.count >= maxAttachments)
                .accessibilityLabel("添加附件")

                TextField("问问钱多多", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.vertical, 11)

                Button {
                    send(text: draft, attachments: attachments)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? AppTheme.primary : Color(.systemGray3)))
                        .frame(width: 44, height: 44)
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 4)
            .aiGlass(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func attachmentThumb(_ attachment: AIAttachment) -> some View {
        Image(uiImage: attachment.image)
            .resizable()
            .scaledToFill()
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    attachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.system(size: 20))
                        .frame(width: 30, height: 30)
                }
                .offset(x: 8, y: -8)
                .accessibilityLabel("移除图片")
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
    }

    // MARK: - Actions

    private func addAttachment(_ image: UIImage) {
        guard attachments.count < maxAttachments else { return }
        attachments.append(AIAttachment(image: image))
    }

    private func openCamera() {
        inputFocused = false
        showingCamera = true
    }

    private var cameraShots: [UIImage] {
        Array(attachments.filter { $0.fileText == nil }.map(\.image).suffix(maxAttachments))
    }

    private func closeCamera() {
        showingCamera = false
    }

    private func send(text: String, attachments: [AIAttachment]) {
        draft = ""
        self.attachments = []
        showingAddMenu = false
        let files = attachments.compactMap { item in
            item.fileText.map { "【文件：\(item.name)】\n\($0)" }
        }
        let fullText = ([text] + files).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let images = attachments.filter { $0.fileText == nil }.map(\.image)
        Task { await session.send(fullText, images: images, displayText: text, fileNames: attachments.filter { $0.fileText != nil }.map(\.name)) }
    }

    private func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        if let image = UIImage(data: data) {
            addAttachment(image)
        } else if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(data: data) {
            for index in 0..<min(document.pageCount, maxAttachments) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 1400 / max(bounds.width, bounds.height, 1)
                addAttachment(page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox))
            }
        } else if let text = String(data: data, encoding: .utf8) {
            guard attachments.count < maxAttachments else { return }
            attachments.append(AIAttachment(image: UIImage(systemName: "doc.text") ?? UIImage(), name: name, fileText: String(text.prefix(20_000))))
        }
    }

    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = max(value.translation.width, 0)
            }
            .onEnded { value in
                let shouldClose = value.translation.width > 120 || value.predictedEndTranslation.width > 260
                if shouldClose {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = UIScreen.main.bounds.width }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { dismiss() }
                    }
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            addMenuRow("相机", systemImage: "camera") { openCamera() }
            addMenuRow("照片", systemImage: "photo") { showingPhotos = true }
            addMenuRow("文件", systemImage: "paperclip") { showingFiles = true }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .aiGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func addMenuRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showingAddMenu = false }
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    @ViewBuilder
    func aiGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

struct AIAttachment: Identifiable {
    let id = UUID()
    let image: UIImage
    var name = ""
    var fileText: String?
}

struct AIAssistantEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("AIAssistantCat")
                .resizable()
                .scaledToFit()
                .frame(height: 62)
        }
        .accessibilityLabel("钱多多助手")
    }
}

struct AIAssistantFloatingCat: View {
    let action: () -> Void
    @AppStorage("aiAssistantCatOffset") private var storedOffset = 0.0
    @GestureState private var drag: Double = 0

    private let catHeight: CGFloat = 62
    private let bottomInset: CGFloat = 64
    private let topInset: CGFloat = 100

    var body: some View {
        GeometryReader { proxy in
            let maxUp = Double(max(proxy.size.height - bottomInset - catHeight - topInset, 0))
            let current = min(max(storedOffset + drag, -maxUp), 0)
            ZStack(alignment: .bottomLeading) {
                Color.clear.allowsHitTesting(false)
                Image("AIAssistantCat")
                    .resizable()
                    .scaledToFit()
                    .frame(height: catHeight)
                    .contentShape(Rectangle())
                    .padding(.bottom, bottomInset - CGFloat(current))
                    .onTapGesture(perform: action)
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .updating($drag) { value, state, _ in state = Double(value.translation.height) }
                            .onEnded { value in
                                storedOffset = min(max(storedOffset + Double(value.translation.height), -maxUp), 0)
                            }
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("钱多多助手")
            }
        }
    }
}

extension AIAssistantSession: Identifiable {}

private struct AINoteField: View {
    let box: AINoteBox
    @State private var text: String

    init(box: AINoteBox) {
        self.box = box
        _text = State(initialValue: box.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(box.label)
                .font(.subheadline)
            TextField("可编辑", text: $text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: text) { _, value in box.text = value }
        }
    }
}
