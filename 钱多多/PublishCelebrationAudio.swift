import AVFoundation
import Combine
import Foundation

@MainActor
final class PublishCelebrationAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = PublishCelebrationAudio()

    @Published private(set) var hasCustomRecording = false
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var ownsPlaybackSession = false
    private var interruptionObserver: AnyCancellable?

    override init() {
        super.init()
        refreshSelection()
        interruptionObserver = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.stop() }
            }
    }

    func refreshSelection() {
        hasCustomRecording = (try? PublishCelebrationSoundStorage.applicationStorage().hasCustomRecording) ?? false
    }

    func playCelebration() {
        do {
            try playSelected(isPreview: false)
        } catch {
            // 自定义文件损坏或不可读取时，发布仍使用通用提示音。
            try? play(data: PublishCelebrationSoundStorage.defaultSoundData(), isPreview: false)
        }
    }

    func previewSelected() throws {
        try playSelected(isPreview: true)
    }

    func previewRecording(at url: URL) throws {
        try play(data: Data(contentsOf: url), isPreview: true)
    }

    func saveRecording(from url: URL) throws {
        try PublishCelebrationSoundStorage.applicationStorage().saveRecording(from: url)
        refreshSelection()
        stop()
    }

    func restoreDefault() throws {
        try PublishCelebrationSoundStorage.applicationStorage().removeCustomRecording()
        refreshSelection()
        stop()
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
        if ownsPlaybackSession {
            ownsPlaybackSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func playSelected(isPreview: Bool) throws {
        let data: Data
        if let storage = try? PublishCelebrationSoundStorage.applicationStorage(), storage.hasCustomRecording {
            data = try Data(contentsOf: storage.customRecordingURL)
        } else {
            data = try PublishCelebrationSoundStorage.defaultSoundData()
        }
        try play(data: data, isPreview: isPreview)
    }

    private func play(data: Data, isPreview: Bool) throws {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            // 主动试听可在静音模式下播放；发布时保留系统静音行为。
            try session.setCategory(isPreview ? .playback : .ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            ownsPlaybackSession = true
            let nextPlayer = try AVAudioPlayer(data: data)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            guard nextPlayer.play() else { throw CelebrationAudioError.playbackFailed }
            player = nextPlayer
            isPlaying = true
        } catch {
            stop()
            throw error
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID else { return }
            self.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

@MainActor
final class PublishCelebrationRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 3

    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isRecording = false
    @Published private(set) var hasDraft = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var permissionDenied = false
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var draftURL: URL?
    private var progressTask: Task<Void, Never>?
    private var isClosed = false
    private var appIsActive = true
    private var ownsRecordingSession = false

    func startRecording() async {
        guard !isRequestingPermission, !isRecording, !isClosed else { return }
        errorMessage = nil
        permissionDenied = false
        isRequestingPermission = true
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        isRequestingPermission = false
        guard !isClosed, appIsActive else { return }
        guard granted else {
            permissionDenied = true
            errorMessage = "需要麦克风权限才能录制声音。你可以在系统设置中允许访问。"
            return
        }

        PublishCelebrationAudio.shared.stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qdd-celebration-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            ownsRecordingSession = true
            let nextRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            nextRecorder.delegate = self
            guard nextRecorder.prepareToRecord() else { throw CelebrationAudioError.recordingFailed }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            guard nextRecorder.record(forDuration: Self.maximumDuration) else {
                throw CelebrationAudioError.recordingFailed
            }
            discardDraft()
            recorder = nextRecorder
            draftURL = url
            duration = 0
            isRecording = true
            progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.isRecording,
                          let recorder = self.recorder else { return }
                    self.duration = min(recorder.currentTime, Self.maximumDuration)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
            errorMessage = "无法开始录音，请稍后重试。"
        }
    }

    func finishRecording() {
        finishRecording(successfully: true)
    }

    func preview() {
        guard hasDraft, let draftURL else { return }
        do {
            try PublishCelebrationAudio.shared.previewRecording(at: draftURL)
        } catch {
            errorMessage = "无法试听这段录音，请重新录制。"
        }
    }

    func save() -> Bool {
        guard hasDraft, !isRecording, let draftURL else { return false }
        do {
            try PublishCelebrationAudio.shared.saveRecording(from: draftURL)
            close()
            return true
        } catch {
            errorMessage = "无法保存录音，请检查设备剩余空间后重试。"
            return false
        }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        guard !active else { return }
        if isRecording { finishRecording(successfully: true) }
        PublishCelebrationAudio.shared.stop()
    }

    func handleInterruption() {
        guard isRecording else { return }
        finishRecording(successfully: false)
    }

    func close() {
        isClosed = true
        progressTask?.cancel()
        progressTask = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        PublishCelebrationAudio.shared.stop()
        discardDraft()
        deactivateSession()
    }

    private func finishRecording(successfully: Bool) {
        guard isRecording, let recorder else { return }
        let recordedDuration = recorder.currentTime
        self.recorder = nil
        recorder.delegate = nil
        recorder.stop()
        progressTask?.cancel()
        progressTask = nil
        isRecording = false
        deactivateSession()

        if successfully, let draftURL,
           let audio = try? AVAudioPlayer(contentsOf: draftURL),
           audio.duration >= 0.5, audio.duration <= Self.maximumDuration + 0.2 {
            duration = min(audio.duration, Self.maximumDuration)
            hasDraft = true
        } else {
            discardDraft()
            errorMessage = successfully && recordedDuration < 0.5
                ? "录音太短，请至少录制半秒后再停止。"
                : "录音被中断，请重新录制。"
        }
    }

    private func discardDraft() {
        if let draftURL { try? FileManager.default.removeItem(at: draftURL) }
        draftURL = nil
        hasDraft = false
        duration = 0
    }

    private func deactivateSession() {
        if ownsRecordingSession {
            ownsRecordingSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let recorderID = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let currentRecorder = self.recorder,
                  ObjectIdentifier(currentRecorder) == recorderID else { return }
            self.finishRecording(successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }
}

private enum CelebrationAudioError: Error {
    case playbackFailed
    case recordingFailed
}
