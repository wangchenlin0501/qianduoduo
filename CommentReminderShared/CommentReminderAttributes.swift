import ActivityKit
import Foundation

// Compile this same definition into the app and the Live Activity extension.
nonisolated struct CommentReminderAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var videoName: String
        var publishedAt: Date
        var fireDate: Date

        var timerInterval: ClosedRange<Date> {
            min(publishedAt, fireDate)...fireDate
        }
    }

    var videoID: String

    var destinationURL: URL? {
        URL(string: "qianduoduo://comment-reminder/\(videoID)")
    }
}
