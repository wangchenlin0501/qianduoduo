import AVFoundation
import Combine
import CoreData
import Foundation
import UIKit

@MainActor
final class PublishCelebrationAudio: NSObject, ObservableObject {
    static let shared = PublishCelebrationAudio()

    @Published private(set) var hasCustomRecording = false
    @Published private(set) var hasUnsyncedLocalRecording = false
    @Published private(set) var canChangeSound = true
    @Published private(set) var isPlaying = false

    private var player: CelebrationPlayback?
    private var playbackSessionID: UUID?
    private var interruptionObserver: AnyCancellable?
    private let soundSync: PublishCelebrationSoundSync
    private var selectionObservers: Set<AnyCancellable> = []

    override init() {
        soundSync = PersistenceController.shared.makeCelebrationSoundSync()
        super.init()
        refreshSelection()
        interruptionObserver = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.stop() }
            }
        // Re-read the active space after imports, invitation changes and returning to the app.
        // No downloaded selection is copied into a global local file or written back to CloudKit.
        Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: soundSync.context),
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange, object: soundSync.context.persistentStoreCoordinator),
            NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification),
            NotificationCenter.default.publisher(for: .adRecordsDidChange),
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSelection() }
        }
        .store(in: &selectionObservers)
    }

    func refreshSelection() {
        hasCustomRecording = soundSync.hasCustomRecording
        hasUnsyncedLocalRecording = soundSync.hasUnsyncedLocalRecording
        canChangeSound = soundSync.canChangeSound
    }

    func playCelebration() async {
        do {
            try await playSelected(isPreview: false)
        } catch is CancellationError {
            return
        } catch {
            // 自定义文件损坏或不可读取时，发布仍使用通用提示音。
            try? await play(data: PublishCelebrationSoundStorage.defaultSoundData(), isPreview: false)
        }
    }

    func previewSelected() async throws {
        try await playSelected(isPreview: true)
    }

    func previewRecording(at url: URL) async throws {
        try await play(data: Data(contentsOf: url), isPreview: true)
    }

    func saveRecording(from url: URL) throws {
        try soundSync.saveRecording(data: Data(contentsOf: url))
        refreshSelection()
        stop()
    }

    func restoreDefault() throws {
        try soundSync.restoreDefault()
        refreshSelection()
        stop()
    }

    func syncExistingRecording() throws {
        try soundSync.syncExistingRecording()
        refreshSelection()
        stop()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        if let id = playbackSessionID {
            playbackSessionID = nil
            CelebrationAudioSession.shared.deactivate(id: id)
        }
    }

    private func playSelected(isPreview: Bool) async throws {
        let data: Data
        if let recording = try soundSync.selectedRecordingData() {
            data = recording
        } else {
            data = try PublishCelebrationSoundStorage.defaultSoundData()
        }
        try await play(data: data, isPreview: isPreview)
    }

    private func play(data: Data, isPreview: Bool) async throws {
        stop()
        let id = UUID()
        playbackSessionID = id
        isPlaying = true
        do {
            // 主动试听可在静音模式下播放；发布时保留系统静音行为。
            try await CelebrationAudioSession.shared.activate(
                id: id, category: isPreview ? .playback : .ambient, options: [.mixWithOthers]
            )
            guard playbackSessionID == id, !Task.isCancelled else { throw CancellationError() }
            let nextPlayer = CelebrationPlayback { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackSessionID == id else { return }
                    self.stop()
                }
            }
            player = nextPlayer
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nextPlayer.start(source: .data(data)) { continuation.resume(with: $0) }
            }
            guard playbackSessionID == id, !Task.isCancelled else { throw CancellationError() }
        } catch {
            guard playbackSessionID == id else { throw CancellationError() }
            stop()
            throw error
        }
    }
}

@MainActor
final class PublishCelebrationRecorder: NSObject, ObservableObject {
    static let maximumDuration: TimeInterval = 3

    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var hasDraft = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var permissionDenied = false
    @Published var errorMessage: String?

    private var recorder: CelebrationRecording?
    private var draftURL: URL?
    private var progressTask: Task<Void, Never>?
    private var isClosed = false
    private var appIsActive = true
    private var recordingSessionID: UUID?
    private var recordingRequestID = UUID()

    func startRecording() async {
        guard !isRequestingPermission, !isRecording, !isFinishingRecording, !isClosed, appIsActive else { return }
        errorMessage = nil
        permissionDenied = false
        isRequestingPermission = true
        let requestID = UUID()
        recordingRequestID = requestID
        defer { isRequestingPermission = false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard !isClosed, appIsActive, recordingRequestID == requestID,
              !Task.isCancelled else { return }
        guard granted else {
            permissionDenied = true
            errorMessage = "需要麦克风权限才能录制声音。你可以在系统设置中允许访问。"
            return
        }

        PublishCelebrationAudio.shared.stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qdd-celebration-\(UUID().uuidString).m4a")
        do {
            let id = UUID()
            recordingSessionID = id
            try await CelebrationAudioSession.shared.activate(
                id: id, category: .playAndRecord, options: [.defaultToSpeaker]
            )
            guard !isClosed, appIsActive, recordingRequestID == requestID,
                  recordingSessionID == id, !Task.isCancelled else { throw CancellationError() }
            let nextRecorder = CelebrationRecording { [weak self] successfully in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingSessionID == id else { return }
                    self.finishRecording(successfully: successfully)
                }
            }
            recorder = nextRecorder
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nextRecorder.start(at: url, maximumDuration: Self.maximumDuration) {
                    continuation.resume(with: $0)
                }
            }
            guard !isClosed, appIsActive, recordingRequestID == requestID,
                  recordingSessionID == id, !Task.isCancelled else { throw CancellationError() }
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
                    let elapsed = await withCheckedContinuation { continuation in
                        recorder.readDuration { continuation.resume(returning: $0) }
                    }
                    guard !Task.isCancelled, self.isRecording, self.recorder === recorder else { return }
                    self.duration = min(elapsed, Self.maximumDuration)
                }
            }
        } catch {
            recorder?.stop()
            recorder = nil
            CelebrationAudioQueue.removeFile(at: url)
            deactivateSession()
            if !(error is CancellationError) {
                errorMessage = "无法开始录音，请稍后重试。"
            }
        }
    }

    func finishRecording() {
        finishRecording(successfully: true)
    }

    func preview() async {
        guard hasDraft, let draftURL else { return }
        do {
            try await PublishCelebrationAudio.shared.previewRecording(at: draftURL)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "无法试听这段录音，请重新录制。"
        }
    }

    func save() -> Bool {
        guard hasDraft, !isRecording, !isFinishingRecording, !isRequestingPermission, let draftURL else { return false }
        do {
            try PublishCelebrationAudio.shared.saveRecording(from: draftURL)
            close()
            return true
        } catch {
            errorMessage = "无法保存录音：\(error.localizedDescription)"
            return false
        }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        guard !active else { return }
        recordingRequestID = UUID()
        if isRecording { finishRecording(successfully: true) }
        else if !isFinishingRecording { recorder?.stop() }
        deactivateSession()
        PublishCelebrationAudio.shared.stop()
    }

    func handleInterruption() {
        recordingRequestID = UUID()
        if isRecording { finishRecording(successfully: false) }
        else if !isFinishingRecording { recorder?.stop() }
        deactivateSession()
    }

    func close() {
        isClosed = true
        recordingRequestID = UUID()
        progressTask?.cancel()
        progressTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        isFinishingRecording = false
        PublishCelebrationAudio.shared.stop()
        discardDraft()
        deactivateSession()
    }

    private func finishRecording(successfully: Bool) {
        guard isRecording, let recorder else { return }
        isRecording = false
        isFinishingRecording = true
        progressTask?.cancel()
        progressTask = nil
        recorder.finish { [weak self] recordedDuration, validatedDuration in
            Task { @MainActor [weak self] in
                guard let self, self.recorder === recorder, !self.isClosed else { return }
                self.recorder = nil
                self.isFinishingRecording = false
                self.deactivateSession()
                if successfully, let validatedDuration,
                   validatedDuration >= 0.5, validatedDuration <= Self.maximumDuration + 0.2 {
                    self.duration = min(validatedDuration, Self.maximumDuration)
                    self.hasDraft = true
                } else {
                    self.discardDraft()
                    self.errorMessage = successfully && recordedDuration < 0.5
                        ? "录音太短，请至少录制半秒后再停止。"
                        : "录音被中断，请重新录制。"
                }
            }
        }
    }

    private func discardDraft() {
        if let draftURL { CelebrationAudioQueue.removeFile(at: draftURL) }
        draftURL = nil
        hasDraft = false
        duration = 0
    }

    private func deactivateSession() {
        if let id = recordingSessionID {
            recordingSessionID = nil
            CelebrationAudioSession.shared.deactivate(id: id)
        }
    }
}

// 会话切换可能阻塞。所有切换按顺序在后台执行，UI 状态仍由 MainActor 管理。
@MainActor
private final class CelebrationAudioSession {
    static let shared = CelebrationAudioSession()
    private let worker = Worker()
    private var currentID: UUID?

    func activate(id: UUID, category: AVAudioSession.Category,
                  options: AVAudioSession.CategoryOptions) async throws {
        currentID = id
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.activate(id: id, category: category, options: options) { result in
                continuation.resume(with: result)
            }
        }
        guard currentID == id else { throw CancellationError() }
    }

    func deactivate(id: UUID) {
        guard currentID == id else { return }
        currentID = nil
        worker.deactivate(id: id)
    }

    // 仅 queue 访问 owner；unchecked Sendable 不用于传递播放器或界面状态。
    nonisolated private final class Worker: @unchecked Sendable {
        private let queue = CelebrationAudioQueue.shared
        private var owner: UUID?

        func activate(id: UUID, category: AVAudioSession.Category,
                      options: AVAudioSession.CategoryOptions,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
            queue.async { [self] in
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(category, mode: .default, options: options)
                    try session.setActive(true)
                    owner = id
                    completion(.success(()))
                } catch {
                    // 配置部分成功时也清理会话；后续请求在同一队列中等待。
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    owner = nil
                    completion(.failure(error))
                }
            }
        }

        func deactivate(id: UUID) {
            queue.async { [self] in
                guard owner == id else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                owner = nil
            }
        }
    }
}

private enum CelebrationAudioError: Error {
    case playbackFailed
    case recordingFailed
}

// AVAudioPlayer.prepareToPlay/play/stop 也会隐式切换会话，必须与显式切换共用队列。
nonisolated private enum CelebrationAudioQueue {
    static let shared = DispatchQueue(label: "com.qianduoduo.celebration-audio", qos: .userInitiated)

    static func removeFile(at url: URL) {
        shared.async { try? FileManager.default.removeItem(at: url) }
    }
}

// 播放器仅在 CelebrationAudioQueue 上创建、访问和释放；delegate 只传递完成事件。
nonisolated final class CelebrationPlayback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    private var player: AVAudioPlayer?
    private let onFinished: @Sendable () -> Void

    init(onFinished: @escaping @Sendable () -> Void = {}) {
        self.onFinished = onFinished
    }

    func start(source: Source, category: AVAudioSession.Category? = nil,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        CelebrationAudioQueue.shared.async { [self] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            do {
                if let category {
                    try AVAudioSession.sharedInstance().setCategory(category, mode: .default)
                }
                let nextPlayer: AVAudioPlayer
                switch source {
                case .data(let data): nextPlayer = try AVAudioPlayer(data: data)
                case .file(let url): nextPlayer = try AVAudioPlayer(contentsOf: url)
                }
                player = nextPlayer
                nextPlayer.delegate = self
                guard nextPlayer.prepareToPlay(), nextPlayer.play() else {
                    throw CelebrationAudioError.playbackFailed
                }
                completion(.success(()))
            } catch {
                stopOnQueue()
                completion(.failure(error))
            }
        }
    }

    func stop() {
        CelebrationAudioQueue.shared.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(CelebrationAudioQueue.shared))
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        CelebrationAudioQueue.shared.async { [self] in
            guard let current = self.player, ObjectIdentifier(current) == playerID else { return }
            stopOnQueue()
            onFinished()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

nonisolated private final class CelebrationRecording: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private let onFinished: @Sendable (Bool) -> Void

    init(onFinished: @escaping @Sendable (Bool) -> Void) {
        self.onFinished = onFinished
    }

    func start(at url: URL, maximumDuration: TimeInterval,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        CelebrationAudioQueue.shared.async { [self] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            do {
                let nextRecorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ])
                recorder = nextRecorder
                nextRecorder.delegate = self
                guard nextRecorder.prepareToRecord() else { throw CelebrationAudioError.recordingFailed }
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                guard nextRecorder.record(forDuration: maximumDuration) else {
                    throw CelebrationAudioError.recordingFailed
                }
                completion(.success(()))
            } catch {
                stopOnQueue()
                completion(.failure(error))
            }
        }
    }

    func readDuration(completion: @escaping @Sendable (TimeInterval) -> Void) {
        CelebrationAudioQueue.shared.async { [self] in completion(recorder?.currentTime ?? 0) }
    }

    func finish(completion: @escaping @Sendable (TimeInterval, TimeInterval?) -> Void) {
        CelebrationAudioQueue.shared.async { [self] in
            let elapsed = recorder?.currentTime ?? 0
            let url = recorder?.url
            stopOnQueue()
            let duration = url.flatMap { try? AVAudioPlayer(contentsOf: $0).duration }
            completion(elapsed, duration)
        }
    }

    func stop() {
        CelebrationAudioQueue.shared.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(CelebrationAudioQueue.shared))
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let recorderID = ObjectIdentifier(recorder)
        CelebrationAudioQueue.shared.async { [self] in
            guard let current = self.recorder, ObjectIdentifier(current) == recorderID else { return }
            onFinished(flag)
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }
}
