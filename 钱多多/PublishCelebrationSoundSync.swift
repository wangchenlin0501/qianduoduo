import CoreData
import Foundation

/// The current business space owns one sound, so existing CloudKit sharing also shares its audio.
@MainActor
final class PublishCelebrationSoundSync {
    static let maximumRecordingBytes = 1_048_576

    let context: NSManagedObjectContext
    private let activeSpace: () throws -> NSManagedObject
    private let existingSpace: () throws -> NSManagedObject?
    private let canUpdate: (NSManagedObject) -> Bool
    private let legacyStorage: PublishCelebrationSoundStorage?

    init(
        context: NSManagedObjectContext,
        activeSpace: @escaping () throws -> NSManagedObject,
        existingSpace: @escaping () throws -> NSManagedObject?,
        canUpdate: @escaping (NSManagedObject) -> Bool,
        legacyStorage: PublishCelebrationSoundStorage?
    ) {
        self.context = context
        self.activeSpace = activeSpace
        self.existingSpace = existingSpace
        self.canUpdate = canUpdate
        self.legacyStorage = legacyStorage
    }

    var canChangeSound: Bool {
        do {
            guard let space = try existingSpace() else { return true }
            return canUpdate(space)
        } catch { return false }
    }

    var hasUnsyncedLocalRecording: Bool {
        do {
            // An explicit default is a synced value too. Never resurrect an old device's file.
            if let space = try existingSpace(), space.value(forKey: "celebrationSoundData") != nil {
                return false
            }
            return legacyStorage?.hasCustomRecording == true
        } catch { return false }
    }

    var hasCustomRecording: Bool {
        do {
            if let space = try existingSpace(),
               let payload = space.value(forKey: "celebrationSoundData") as? Data {
                // Keep reset available even if a downloaded selection is corrupt or from a newer app.
                guard payload.count <= Self.maximumRecordingBytes + 4096,
                      let selection = try? PropertyListDecoder().decode(Selection.self, from: payload),
                      selection.version == 1 else { return true }
                return selection.audio != nil
            }
            return legacyStorage?.hasCustomRecording == true
        } catch { return false }
    }

    func selectedRecordingData() throws -> Data? {
        if let space = try existingSpace(),
           let payload = space.value(forKey: "celebrationSoundData") as? Data {
            guard payload.count <= Self.maximumRecordingBytes + 4096 else { throw SoundError.invalidRecording }
            let selection = try PropertyListDecoder().decode(Selection.self, from: payload)
            guard selection.version == 1 else { throw SoundError.unsupportedVersion }
            if let data = selection.audio { try validate(data) }
            return selection.audio
        }
        guard let legacyStorage, legacyStorage.hasCustomRecording else { return nil }
        let data = try Data(contentsOf: legacyStorage.customRecordingURL)
        try validate(data)
        return data
    }

    func saveRecording(data: Data) throws {
        try validate(data)
        try saveSelection(Selection(version: 1, audio: data))
    }

    func restoreDefault() throws {
        try saveSelection(Selection(version: 1, audio: nil))
    }

    func syncExistingRecording() throws {
        guard hasUnsyncedLocalRecording, let legacyStorage else { throw SoundError.noLocalRecording }
        try saveRecording(data: Data(contentsOf: legacyStorage.customRecordingURL))
    }

    private func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumRecordingBytes else { throw SoundError.invalidRecording }
    }

    private func saveSelection(_ selection: Selection) throws {
        let space = try activeSpace()
        guard canUpdate(space) else { throw SoundError.readOnly }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(selection)
        let previousData = space.value(forKey: "celebrationSoundData")
        let previousUpdatedAt = space.value(forKey: "updatedAt")
        space.setValue(payload, forKey: "celebrationSoundData")
        space.setValue(Date(), forKey: "updatedAt")
        do {
            try context.save()
        } catch {
            // Do not roll back unrelated edits in the shared view context.
            space.setValue(previousData, forKey: "celebrationSoundData")
            space.setValue(previousUpdatedAt, forKey: "updatedAt")
            throw error
        }
        // The database is now authoritative, including offline changes waiting for CloudKit.
        // A failed cache cleanup must not turn a successful database save into a failed action.
        try? legacyStorage?.removeCustomRecording()
    }

    /// Store the choice and its default/reset marker in one CloudKit field to avoid split conflicts.
    private struct Selection: Codable {
        let version: Int
        let audio: Data?
    }

    enum SoundError: LocalizedError {
        case invalidRecording, unsupportedVersion, noLocalRecording, readOnly

        var errorDescription: String? {
            switch self {
            case .invalidRecording: "录音为空或过大，请重新录制。"
            case .unsupportedVersion: "请更新应用后再使用这段同步音效。"
            case .noLocalRecording: "没有需要同步的本机录音。"
            case .readOnly: "当前共享只允许查看，无法更换音效。"
            }
        }
    }
}
