import AVFoundation
import Foundation
import Testing
@testable import 钱多多

@MainActor
@Suite(.serialized)
struct PublishCelebrationAudioTests {
    @Test func previewCanPreparePlayAndStop() async throws {
        let audio = PublishCelebrationAudio.shared
        defer { audio.stop() }
        try await audio.previewSelected()
        #expect(audio.isPlaying)
        audio.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!audio.isPlaying)
    }

    @Test func playbackCompletionClearsPlayingState() async throws {
        let url = try makeTemporarySound()
        let audio = PublishCelebrationAudio.shared
        defer {
            audio.stop()
            try? FileManager.default.removeItem(at: url)
        }
        try await audio.previewRecording(at: url)
        #expect(audio.isPlaying)
        for _ in 0..<50 {
            if !audio.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!audio.isPlaying, "The background player must deliver its completion callback")
    }

    @Test func stoppingDuringStartupDoesNotRestartPlayback() async throws {
        let audio = PublishCelebrationAudio.shared
        defer { audio.stop() }
        for _ in 0..<10 {
            let attempt = Task { try await audio.previewSelected() }
            for _ in 0..<100 {
                if audio.isPlaying { break }
                await Task.yield()
            }
            audio.stop()
            do { try await attempt.value }
            catch is CancellationError { }
            try await Task.sleep(for: .milliseconds(30))
            #expect(!audio.isPlaying)
        }
    }

    @Test func reminderPreviewUsesBackgroundPlayer() async throws {
        let url = try makeTemporarySound()
        let player = CelebrationPlayback()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: url)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.start(source: .file(url), category: .ambient) { continuation.resume(with: $0) }
        }
        player.stop()
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(at: url)
    }

    @Test func failedPlaybackResetsStateAndAllowsRetry() async throws {
        let audio = PublishCelebrationAudio.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-audio-\(UUID()).wav")
        try Data([0, 1, 2]).write(to: url)
        defer {
            audio.stop()
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try await audio.previewRecording(at: url)
            Issue.record("Invalid audio should fail to start")
        } catch { }
        #expect(!audio.isPlaying)
        try await audio.previewSelected()
        #expect(audio.isPlaying)
    }

    @Test func closedOrBackgroundRecorderDoesNotRequestMicrophonePermission() async {
        let permission = AVAudioApplication.shared.recordPermission
        let closed = PublishCelebrationRecorder()
        closed.close()
        await closed.startRecording()
        #expect(!closed.isRecording)
        let background = PublishCelebrationRecorder()
        background.setAppActive(false)
        await background.startRecording()
        #expect(!background.isRecording)
        #expect(AVAudioApplication.shared.recordPermission == permission)
        background.close()
    }

    @Test(.enabled(if: AVAudioApplication.shared.recordPermission == .granted,
                   "Recording tests require previously granted microphone permission"))
    func recordingCanFinishPreviewAndDiscardWithoutSaving() async throws {
        let recorder = PublishCelebrationRecorder()
        defer { recorder.close() }
        await recorder.startRecording()
        #expect(recorder.isRecording)
        try await Task.sleep(for: .milliseconds(700))
        recorder.finishRecording()
        for _ in 0..<30 {
            if !recorder.isFinishingRecording { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!recorder.isFinishingRecording)
        #expect(recorder.hasDraft)
        await recorder.preview()
        #expect(PublishCelebrationAudio.shared.isPlaying)
        recorder.close()
        #expect(!recorder.hasDraft)
        #expect(!PublishCelebrationAudio.shared.isPlaying)
    }

    private func makeTemporarySound() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-\(UUID()).wav")
        try PublishCelebrationSoundStorage.defaultSoundData().write(to: url)
        return url
    }
}
