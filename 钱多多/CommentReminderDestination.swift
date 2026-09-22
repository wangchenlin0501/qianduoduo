import CoreData
import SwiftUI

/// Used by both notification taps and the Dynamic Island.
struct CommentReminderDestination: View {
    @Environment(\.dismiss) private var dismiss
    let reminderID: String
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: true)])
    private var allRecords: FetchedResults<AdRecord>

    private var group: VideoGroup? {
        let records = allRecords.filter { CommentReminderStore.eventID(for: $0) == reminderID }
        return makeVideoGroups(from: records).first
    }

    var body: some View {
        Group {
            if let group {
                VideoDetailView(group: group)
            } else {
                ContentUnavailableView(
                    "暂未找到这条视频", systemImage: "icloud",
                    description: Text("视频可能尚未同步、已取消发布或已删除。同步完成后会自动显示。")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
    }
}
