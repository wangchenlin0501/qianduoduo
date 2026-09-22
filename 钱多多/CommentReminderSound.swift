import AVFoundation
import Foundation
import UserNotifications

/// 本机选择的提醒声音。短 PCM 音频保存在系统通知支持的 Library/Sounds 中。
enum CommentReminderSound: String, CaseIterable, Identifiable {
    case system
    case chime
    case softDouble

    var id: String { rawValue }

    static var selected: CommentReminderSound {
        CommentReminderSound(
            rawValue: UserDefaults.standard.string(forKey: "commentReminderSound") ?? ""
        ) ?? .system
    }

    var title: String {
        switch self {
        case .system: return "系统默认"
        case .chime: return "清亮钟声"
        case .softDouble: return "柔和双响"
        }
    }

    var notificationSound: UNNotificationSound {
        guard let url = preparedFileURL() else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
    }

    static func ensureSoundsAvailable() {
        for sound in allCases where sound != .system {
            _ = sound.preparedFileURL()
        }
    }

    func preview() {
        if self == .system {
            // iOS 没有直接播放用户默认通知音的公开 API，通过本机通知试听原音。
            VideoCommentNotificationManager.shared.scheduleTestNotification { _ in }
            return
        }
        guard let url = preparedFileURL() else { return }
        CommentReminderSoundPreview.shared.play(url)
    }

    private var fileName: String? {
        switch self {
        case .system: return nil
        case .chime: return "qdd-comment-chime-v1.wav"
        case .softDouble: return "qdd-comment-soft-double-v1.wav"
        }
    }

    private func preparedFileURL() -> URL? {
        guard let fileName else { return nil }
        do {
            let library = try FileManager.default.url(
                for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let directory = library.appendingPathComponent("Sounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try waveData().write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            }
            return url
        } catch {
            AppLogger.shared.log("准备提醒声音失败，将使用系统默认音：\(error.localizedDescription)")
            return nil
        }
    }

    private struct Note {
        let frequency: Double
        let start: Double
        let duration: Double
        let amplitude: Double
    }

    private func waveData() -> Data {
        let sampleRate = 44_100
        let duration: Double
        let notes: [Note]
        switch self {
        case .system:
            return Data()
        case .chime:
            duration = 1.45
            notes = [
                Note(frequency: 783.99, start: 0, duration: 0.9, amplitude: 0.46),
                Note(frequency: 1_046.5, start: 0.28, duration: 1.05, amplitude: 0.42)
            ]
        case .softDouble:
            duration = 1.85
            notes = [
                Note(frequency: 523.25, start: 0, duration: 0.56, amplitude: 0.45),
                Note(frequency: 659.25, start: 0.18, duration: 0.63, amplitude: 0.4),
                Note(frequency: 523.25, start: 0.83, duration: 0.56, amplitude: 0.45),
                Note(frequency: 659.25, start: 1.01, duration: 0.7, amplitude: 0.4)
            ]
        }

        let sampleCount = Int(Double(sampleRate) * duration)
        let payloadSize = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(payloadSize))
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(payloadSize + 36, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data) // Linear PCM
        appendLittleEndian(UInt16(1), to: &data) // Mono
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(payloadSize, to: &data)

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            var value = 0.0
            for note in notes {
                let localTime = time - note.start
                guard localTime >= 0, localTime < note.duration else { continue }
                let attack = min(localTime / 0.012, 1)
                let release = min((note.duration - localTime) / 0.05, 1)
                let decay = exp(-4 * localTime / note.duration)
                let phase = 2 * Double.pi * note.frequency * localTime
                let tone = sin(phase) + 0.17 * sin(phase * 2) + 0.045 * sin(phase * 3)
                value += tone * note.amplitude * attack * release * decay
            }
            let limitedValue = min(max(value, -0.92), 0.92)
            let sample = Int16((limitedValue * Double(Int16.max)).rounded())
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }
}

@MainActor
private final class CommentReminderSoundPreview {
    static let shared = CommentReminderSoundPreview()
    private var player: AVAudioPlayer?

    func play(_ url: URL) {
        do {
            player?.stop()
            // ambient 保留系统静音行为，不抢占其他应用的音频。
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
        } catch {
            AppLogger.shared.log("试听提醒声音失败：\(error.localizedDescription)")
        }
    }
}
