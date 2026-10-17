import Foundation

/// 用户的庆祝录音只保存在本机，不进入 iCloud 同步或设备备份。
struct PublishCelebrationSoundStorage {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func applicationStorage() throws -> Self {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storage = Self(directory: support.appendingPathComponent("PublishCelebrationSound", isDirectory: true))
        try storage.prepareDirectory()
        return storage
    }

    var customRecordingURL: URL {
        directory.appendingPathComponent("custom.m4a", isDirectory: false)
    }

    var hasCustomRecording: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: customRecordingURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func saveRecording(from sourceURL: URL) throws {
        let source = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard source.isRegularFile == true, let size = source.fileSize, size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try prepareDirectory()
        let manager = FileManager.default
        let stagedURL = directory.appendingPathComponent(".recording-\(UUID().uuidString).m4a")
        defer { try? manager.removeItem(at: stagedURL) }

        try manager.copyItem(at: sourceURL, to: stagedURL)
        try Self.protectLocalFile(at: stagedURL)

        var existingIsDirectory: ObjCBool = false
        if manager.fileExists(atPath: customRecordingURL.path, isDirectory: &existingIsDirectory) {
            guard !existingIsDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
            _ = try manager.replaceItemAt(
                customRecordingURL,
                withItemAt: stagedURL,
                options: .usingNewMetadataOnly
            )
        } else {
            try manager.moveItem(at: stagedURL, to: customRecordingURL)
        }
    }

    func removeCustomRecording() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: customRecordingURL.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
        try manager.removeItem(at: customRecordingURL)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protectLocalFile(at: directory)
    }

    private static func protectLocalFile(at url: URL) throws {
        var localURL = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try localURL.setResourceValues(resources)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// CC0 多人欢呼素材；来源与处理记录随资源保存在许可说明中。
    static func defaultSoundData(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "PublishCelebrationDefault", withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
