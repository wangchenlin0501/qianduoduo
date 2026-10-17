import CoreData
import SwiftUI

enum VideoViewMode: String, CaseIterable, Identifiable {
    case list = "列表"
    case calendar = "日历"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .list: "rectangle.grid.1x2.fill"
        case .calendar: "calendar"
        }
    }
}

struct VideoViewModeToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var viewMode: VideoViewMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(VideoViewMode.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        viewMode = mode
                    }
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(viewMode == mode ? AppTheme.onPrimary : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(viewMode == mode ? AppTheme.primary : Color(uiColor: .tertiarySystemFill), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(viewMode == mode ? AppTheme.primary.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue)模式")
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
            }
        }
    }
}

struct VideoMonthCalendar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let month: Date
    let groups: [VideoGroup]
    let dragScope: UUID
    let openVideo: (VideoGroup) -> Void
    let generateBrandImage: (String) -> Void
    let addVideo: (Date) -> Void
    let resolveDestination: (String, Date) -> Date?
    let moveVideo: (String, Date) -> Date?

    @ScaledMetric(relativeTo: .caption2) private var cellHeight = 80.0
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7)

    var body: some View {
        let days = VideoCalendarMonth(containing: month, calendar: qddCalendar).days

        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(weekdays.indices, id: \.self) { index in
                    Text(weekdays[index])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index < 5 ? weekdayLabelColor : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .accessibilityLabel("星期\(weekdays[index])")
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055))
                .frame(height: 1 / displayScale)
                .padding(.horizontal, 10)

            VideoCalendarCollectionView(
                days: days,
                groups: groups,
                dragScope: dragScope,
                rowHeight: cellHeight,
                openVideo: openVideo,
                generateBrandImage: generateBrandImage,
                addVideo: addVideo,
                resolveDestination: resolveDestination,
                moveVideo: moveVideo
            )
            .frame(height: CGFloat(days.count / 7) * cellHeight)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.readablePrimary.opacity(colorScheme == .dark ? 0.24 : 0.12), lineWidth: 1 / displayScale)
        }
    }

    private var weekdayLabelColor: Color {
        AppTheme.readablePrimary
    }
}
