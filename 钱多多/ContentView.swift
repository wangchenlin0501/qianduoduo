//
//  ContentView.swift
//  钱多多
//

import CoreData
import SwiftUI

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = 0
    @State private var presentedAssistant: AIAssistantSession?
    @State private var assistantSession: AIAssistantSession?
    @ObservedObject private var reminders = VideoCommentNotificationManager.shared

    private var currentPageName: String {
        let names = ["汇总", "池子", "视频", "账本", "待办"]
        return names.indices.contains(selectedTab) ? names[selectedTab] : "汇总"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SummaryPage()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("汇总", systemImage: "chart.bar.fill")
                }
                .tag(0)

            PoolPage()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("池子", systemImage: "tray.full.fill")
                }
                .tag(1)

            VideosPage()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("视频", systemImage: "calendar")
                }
                .tag(2)

            LedgerPage()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("账本", systemImage: "list.clipboard.fill")
                }
                .tag(3)

            TodoPage()
                .tabItem {
                    Label("待办", systemImage: "checklist")
                }
                .tag(4)

        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onReceive(NotificationCenter.default.publisher(for: .aiAssistantNavigate)) { note in
            guard let tab = note.userInfo?["tab"] as? Int else { return }
            selectedTab = tab
            presentedAssistant = nil
        }
        .environment(\.appThemeColor, AppThemeSettings.shared.color)
        .tint(AppTheme.readablePrimary)
        .overlay(alignment: .bottomLeading) {
            AIAssistantFloatingCat {
                if let assistantSession {
                    assistantSession.pageName = currentPageName
                } else {
                    assistantSession = AIAssistantSession(context: viewContext, pageName: currentPageName)
                }
                presentedAssistant = assistantSession
            }
                .ignoresSafeArea(.keyboard)
        }
        .fullScreenCover(item: $presentedAssistant) { session in
            AIAssistantView(session: session)
                .environment(\.managedObjectContext, viewContext)
                .tint(AppTheme.readablePrimary)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: Binding(
            get: { reminders.openedReminder != nil },
            set: { isPresented in
                if !isPresented {
                    reminders.openedReminder = nil
                }
            }
        )) {
            NavigationStack {
                if let link = reminders.openedReminder {
                    CommentReminderDestination(reminderID: link.id)
                }
            }
            .environment(\.managedObjectContext, viewContext)
            .id(reminders.openedReminder?.id ?? "reminder")
        }
        .onAppear {
            PersistenceController.shared.repairOwnedShareMembership()
            reminders.configure(container: PersistenceController.shared.container)
        }
        .task {
            TodoWidgetBridge.shared.configure(persistence: .shared)
            await reminders.publicationDidSave()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                TodoWidgetBridge.shared.requestRefresh()
                PersistenceController.shared.repairOwnedShareMembership()
                Task { await reminders.publicationDidSave() }
            } else if newPhase == .background {
                Task { try? await TodoWidgetBridge.shared.refreshNow() }
            }
        }
        .onChange(of: AppThemeSettings.shared.color) { _, _ in
            TodoWidgetBridge.shared.requestRefresh()
        }
        .onOpenURL { url in
            if url.scheme == "qianduoduo", url.host == "assistant-share" {
                let images = AIShareInbox.takeImages()
                guard !images.isEmpty else { return }
                let session = assistantSession ?? AIAssistantSession(context: viewContext, pageName: currentPageName)
                assistantSession = session
                session.pageName = currentPageName
                presentedAssistant = session
                Task { await session.send("我从相册分享了截图，请识别并处理。", images: images, displayText: "分享的截图") }
                return
            }
            if url.scheme == "qianduoduo", url.host == "todo" {
                reminders.openedReminder = nil
                selectedTab = 4
            }
            else { reminders.open(url) }
        }
        .onChange(of: reminders.openedReminder?.id) { _, id in
            guard id != nil else { return }
            selectedTab = 2
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
