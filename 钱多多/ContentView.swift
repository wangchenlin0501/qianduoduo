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
    @ObservedObject private var reminders = VideoCommentNotificationManager.shared

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

        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.appThemeColor, AppThemeSettings.shared.color)
        .tint(AppTheme.readablePrimary)
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
            await reminders.publicationDidSave()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PersistenceController.shared.repairOwnedShareMembership()
                Task { await reminders.publicationDidSave() }
            }
        }
        .onOpenURL { reminders.open($0) }
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
