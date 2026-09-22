import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct CommentReminderWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommentReminderLiveActivity()
    }
}

private enum ReminderAppearance {
    static let brown = Color(red: 139.0 / 255, green: 94.0 / 255, blue: 60.0 / 255)
    static let islandBrown = Color(red: 204.0 / 255, green: 162.0 / 255, blue: 126.0 / 255)

    static let timeStyle = Date.FormatStyle(
        date: .omitted,
        time: .shortened,
        locale: Locale(identifier: "zh_Hans_CN"),
        timeZone: TimeZone(identifier: "Asia/Shanghai")!
    )
}

struct CommentReminderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommentReminderAttributes.self) { context in
            CommentReminderLockScreenView(context: context)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.attributes.destinationURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("评论品牌名", systemImage: "text.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ReminderAppearance.islandBrown)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Text("待评论")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ReminderAppearance.islandBrown)
                    } else {
                        ReminderCountdown(state: context.state)
                            .font(.title3.weight(.semibold))
                            .frame(width: 100, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.videoName)
                            .font(.headline)
                            .lineLimit(2)
                        Text(context.isStale ? "时间已到，请评论品牌名" : "倒计时结束后，请评论品牌名")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(ReminderAppearance.islandBrown)
            } compactTrailing: {
                if context.isStale {
                    Text("待评论")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ReminderAppearance.islandBrown)
                } else {
                    ReminderCountdown(state: context.state)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 60)
                }
            } minimal: {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(ReminderAppearance.islandBrown)
            }
            .widgetURL(context.attributes.destinationURL)
            .keylineTint(ReminderAppearance.islandBrown)
        }
    }
}

private struct CommentReminderLockScreenView: View {
    let context: ActivityViewContext<CommentReminderAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "text.bubble.fill")
                .font(.title3)
                .foregroundStyle(ReminderAppearance.brown)
                .frame(width: 42, height: 42)
                .background(ReminderAppearance.brown.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 5) {
                Text(context.isStale ? "请评论品牌名" : "评论品牌名")
                    .font(.subheadline.weight(.semibold))
                Text(context.state.videoName)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("提醒时间 \(context.state.fireDate.formatted(ReminderAppearance.timeStyle))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                if context.isStale {
                    Text("待评论")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ReminderAppearance.brown)
                } else {
                    ReminderCountdown(state: context.state)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .frame(width: 116, alignment: .trailing)
                    Text("距评论")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(18)
    }
}

private struct ReminderCountdown: View {
    let state: CommentReminderAttributes.ContentState

    var body: some View {
        // A bounded system timer stops at zero even when the app is suspended.
        Text(timerInterval: state.timerInterval, countsDown: true, showsHours: true)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}
