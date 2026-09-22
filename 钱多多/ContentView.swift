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
    @State private var summaryTapCount = 0
    @State private var showingSettings = false
    @ObservedObject private var reminders = VideoCommentNotificationManager.shared

    var body: some View {
        TabView(selection: tabSelection) {
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
        .tint(AppTheme.primary)
        .sheet(isPresented: Binding(
            get: { showingSettings || reminders.openedReminder != nil },
            set: { isPresented in
                if !isPresented {
                    showingSettings = false
                    reminders.openedReminder = nil
                }
            }
        )) {
            NavigationStack {
                if let link = reminders.openedReminder {
                    CommentReminderDestination(reminderID: link.id)
                } else {
                    SettingsPage()
                }
            }
            .environment(\.managedObjectContext, viewContext)
            .id(reminders.openedReminder?.id ?? "settings")
        }
        .onAppear {
            PersistenceController.shared.repairOwnedShareMembership(in: viewContext)
            reminders.configure(container: PersistenceController.shared.container)
        }
        .task {
            await reminders.publicationDidSave()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PersistenceController.shared.repairOwnedShareMembership(in: viewContext)
                Task { await reminders.publicationDidSave() }
            }
        }
        .onOpenURL { reminders.open($0) }
        .onChange(of: reminders.openedReminder?.id) { _, id in
            guard id != nil else { return }
            showingSettings = false
            selectedTab = 2
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == 0 && selectedTab == 0 {
                    summaryTapCount += 1
                    if summaryTapCount >= 5 {
                        summaryTapCount = 0
                        showingSettings = true
                    }
                } else {
                    summaryTapCount = 0
                }
                selectedTab = newTab
            }
        )
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
