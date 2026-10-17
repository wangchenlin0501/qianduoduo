import AVFoundation
import Foundation
import Testing
#if os(macOS)
import Darwin
#endif
@testable import 钱多多

@MainActor
struct PublishCelebrationSoundStorageTests {
    @Test func defaultCelebrationResourceIsACompleteAudiblePCMFile() throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let sound = try PublishCelebrationSoundStorage.defaultSoundData(bundle: bundle)
        try #require(sound.count >= 44)
        try #require((sound.count - 44).isMultiple(of: 2))
        let frameCount = 80_687
        let expectedDuration = Double(frameCount) / 44_100
        #expect(sound.count == 44 + frameCount * 2)
        #expect(String(decoding: sound[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: sound[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: sound[36..<40], as: UTF8.self) == "data")
        #expect(unsigned32(sound, at: 4) == UInt32(sound.count - 8))
        #expect(unsigned32(sound, at: 16) == 16)
        #expect(unsigned16(sound, at: 20) == 1)
        #expect(unsigned16(sound, at: 22) == 1)
        #expect(unsigned32(sound, at: 24) == 44_100)
        #expect(unsigned32(sound, at: 28) == 88_200)
        #expect(unsigned16(sound, at: 32) == 2)
        #expect(unsigned16(sound, at: 34) == 16)
        #expect(unsigned32(sound, at: 40) == UInt32(sound.count - 44))
        let duration = Double(sound.count - 44) / 88_200
        #expect(abs(duration - expectedDuration) < 0.001)

        let samples = stride(from: 44, to: sound.count, by: 2).map { index in
            Int(Int16(bitPattern: unsigned16(sound, at: index)))
        }
        #expect(samples.first == 0)
        #expect(samples.last == 0)
        let peak = try #require(samples.map { abs($0) }.max())
        #expect(peak > 1_000)
        #expect(peak < Int(Int16.max))
        #expect(sound == (try PublishCelebrationSoundStorage.defaultSoundData(bundle: bundle)))

        let decoded = try AVAudioPlayer(data: sound)
        #expect(abs(decoded.duration - expectedDuration) < 0.001)
        #expect(decoded.numberOfChannels == 1)
    }

    @Test func saveReplaceAndRestoreDefaultKeepsSourceFiles() throws {
        try withStorage { storage, root in
            let firstSource = root.appendingPathComponent("first.m4a")
            let secondSource = root.appendingPathComponent("second.m4a")
            let first = Data([1, 2, 3])
            let second = Data([4, 5, 6, 7])
            try first.write(to: firstSource)
            try second.write(to: secondSource)
            #expect(!storage.hasCustomRecording)

            try storage.saveRecording(from: firstSource)
            #expect(storage.hasCustomRecording)
            #expect(try Data(contentsOf: storage.customRecordingURL) == first)
            #expect(try Data(contentsOf: firstSource) == first)
            #expect(try isExcludedFromBackup(storage.customRecordingURL))
            #expect(try isExcludedFromBackup(storage.directory))

            try storage.saveRecording(from: secondSource)
            #expect(try Data(contentsOf: storage.customRecordingURL) == second)
            #expect(try Data(contentsOf: secondSource) == second)
            #expect(try isExcludedFromBackup(storage.customRecordingURL))
            #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path) == ["custom.m4a"])

            try storage.removeCustomRecording()
            #expect(!storage.hasCustomRecording)
            #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path).isEmpty)
            try storage.removeCustomRecording()
        }
    }

    @Test func missingEmptyOrDirectorySourcePreservesExistingRecording() throws {
        try withStorage { storage, root in
            let originalSource = root.appendingPathComponent("original.m4a")
            let original = Data([8, 9, 10])
            try original.write(to: originalSource)
            try storage.saveRecording(from: originalSource)
            let emptySource = root.appendingPathComponent("empty.m4a")
            try Data().write(to: emptySource)

            for source in [root.appendingPathComponent("missing.m4a"), emptySource, root] {
                #expect(throws: (any Error).self) { try storage.saveRecording(from: source) }
                #expect(try Data(contentsOf: storage.customRecordingURL) == original)
                #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path) == ["custom.m4a"])
            }
        }
    }

    @Test func failedReplacementCleansStagingAndPreservesOriginalDestination() throws {
        try withStorage { storage, root in
            let source = root.appendingPathComponent("source.m4a")
            try Data([11, 12]).write(to: source)
            try FileManager.default.createDirectory(at: storage.customRecordingURL, withIntermediateDirectories: true)
            let marker = storage.customRecordingURL.appendingPathComponent("keep.txt")
            try Data([13]).write(to: marker)
            #expect(!storage.hasCustomRecording)
            #expect(throws: (any Error).self) { try storage.saveRecording(from: source) }
            #expect(try Data(contentsOf: marker) == Data([13]))
            #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path) == ["custom.m4a"])
            #expect(throws: (any Error).self) { try storage.removeCustomRecording() }
        }
    }

    @Test func restoringDefaultWithoutDirectoryDoesNothing() throws {
        try withStorage { storage, _ in
            try storage.removeCustomRecording()
            #expect(!FileManager.default.fileExists(atPath: storage.directory.path))
        }
    }

    private func withStorage(_ action: (PublishCelebrationSoundStorage, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(PublishCelebrationSoundStorage(directory: root.appendingPathComponent("sound", isDirectory: true)), root)
    }

    private func unsigned16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private func unsigned32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        #if os(macOS)
        // macOS 的临时目录读取公开资源值时会返回 false，直接检查已写入的备份排除标记。
        let key = "com.apple.metadata:com_apple_backup_excludeItem"
        let length = getxattr(url.path, key, nil, 0, 0, 0)
        guard length > 0 else { return false }
        var data = Data(count: length)
        let readLength = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, key, buffer.baseAddress, length, 0, 0)
        }
        guard readLength == length else { return false }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? String == "com.apple.backupd"
        #else
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        #endif
    }
}
