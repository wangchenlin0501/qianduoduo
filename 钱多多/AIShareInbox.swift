//
//  AIShareInbox.swift
//  钱多多
//

import UIKit

/// Screenshots handed over by the share extension through the App Group container.
enum AIShareInbox {
    private static let groupID = Bundle.main.object(forInfoDictionaryKey: "QDDAppGroupIdentifier") as? String ?? "group.com.example.qianduoduo"

    static func takeImages() -> [UIImage] {
        guard let inbox = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("ShareInbox", isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else {
            return []
        }
        let images = files
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { UIImage(data: $0) }
        try? FileManager.default.removeItem(at: inbox)
        return images
    }
}
