import SwiftUI
import WidgetKit

struct TodoListWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TodoWidgetSnapshot
}

struct TodoListWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoListWidgetEntry {
        TodoListWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoListWidgetEntry) -> Void) {
        completion(TodoListWidgetEntry(
            date: .now,
            snapshot: context.isPreview ? .placeholder : (TodoWidgetSnapshotFile.read() ?? .unavailable)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoListWidgetEntry>) -> Void) {
        let now = Date.now
        let snapshot = TodoWidgetSnapshotFile.read() ?? .unavailable
        let halfHour = now.addingTimeInterval(30 * 60)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? halfHour
        // The app supplies the shared snapshot. This refresh only updates its date labels.
        completion(Timeline(
            entries: [TodoListWidgetEntry(date: now, snapshot: snapshot)],
            policy: .after(min(halfHour, nextDay))
        ))
    }
}

struct TodoListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodoWidgetSnapshot.kind, provider: TodoListWidgetProvider()) { entry in
            TodoListWidgetContainer(entry: entry)
        }
        .configurationDisplayName("ToDo List")
        .description("查看当前数据空间的待办，直接勾选完成。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct TodoListWidgetContainer: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodoListWidgetEntry

    var body: some View {
        TodoWidgetEntryView(
            snapshot: entry.snapshot,
            size: family == .systemSmall ? .small : (family == .systemLarge ? .large : .medium),
            referenceDate: entry.date
        )
        .privacySensitive()
        .widgetURL(TodoWidgetSnapshot.destinationURL)
        .containerBackground(.background, for: .widget)
    }
}
