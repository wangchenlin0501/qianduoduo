import AVFoundation
import SwiftUI
import UIKit

struct PublishCelebrationSoundSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var audio = PublishCelebrationAudio.shared
    @State private var showingRecorder = false
    @State private var showingRestoreConfirmation = false
    @State private var errorMessage: String?

    private var soundDescription: String {
        var description = "录音会同步给你的其他设备和共享成员。发布时跟随系统静音。"
        if audio.hasUnsyncedLocalRecording {
            description += "旧录音需手动同步。"
        }
        if !audio.canChangeSound {
            description += "当前共享只读，不能更换音效。"
        }
        return description
    }

    private var soundName: String {
        if audio.hasUnsyncedLocalRecording { return "本机录音（未同步）" }
        return audio.hasCustomRecording ? "自定义录音" : "默认庆祝音"
    }

    var body: some View {
        SettingsCardSection(
            "发布庆祝音效"
        ) {
            SettingsValueRow("当前音效", systemImage: "waveform") {
                Text(soundName)
                    .foregroundStyle(.secondary)
            }

            SettingsRowDivider()

            Button {
                if audio.isPlaying {
                    audio.stop()
                } else {
                    Task {
                        do { try await audio.previewSelected() }
                        catch is CancellationError { }
                        catch { errorMessage = "无法播放，请重录或恢复默认。" }
                    }
                }
            } label: {
                Label(audio.isPlaying ? "停止试听" : "试听音效", systemImage: audio.isPlaying ? "stop.circle" : "play.circle")
                    .settingsRow()
            }

            SettingsRowDivider()

            Button {
                audio.stop()
                showingRecorder = true
            } label: {
                Label(audio.hasCustomRecording ? "重新录制声音" : "录制我的声音", systemImage: "mic")
                    .settingsRow()
            }
            .disabled(!audio.canChangeSound)

            if audio.hasUnsyncedLocalRecording {
                SettingsRowDivider()

                Button {
                    do { try audio.syncExistingRecording() }
                    catch { errorMessage = error.localizedDescription }
                } label: {
                    Label("同步已有录音", systemImage: "icloud.and.arrow.up")
                        .settingsRow()
                }
                .disabled(!audio.canChangeSound)
            }

            if audio.hasCustomRecording {
                SettingsRowDivider()

                Button {
                    showingRestoreConfirmation = true
                } label: {
                    Label("恢复默认音效", systemImage: "arrow.counterclockwise")
                        .settingsRow()
                }
                .disabled(!audio.canChangeSound)
            }
        }
        .onAppear { audio.refreshSelection() }
        .onDisappear { audio.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { audio.stop() }
        }
        .sheet(isPresented: $showingRecorder) {
            PublishCelebrationRecordingSheet()
        }
        .confirmationDialog("恢复默认音效？", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
            Button("恢复默认音效", role: .destructive) {
                do { try audio.restoreDefault() }
                catch { errorMessage = error.localizedDescription }
            }
            .disabled(!audio.canChangeSound)
            Button("取消", role: .cancel) { }
        } message: {
            Text("其他设备和共享成员也会恢复默认音效。")
        }
        .alert("音效", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct PublishCelebrationRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = PublishCelebrationRecorder()
    @ObservedObject private var audio = PublishCelebrationAudio.shared

    var body: some View {
        NavigationStack {
            List {
                SettingsCardSection(
                    recorder.isRecording ? "正在录音" : recorder.hasDraft ? "试听录音" : "录制声音",
                    footer: "保存后会同步给其他设备和共享成员。"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("最长 3 秒，可先试听。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(String(format: "%.1f / 3.0 秒", recorder.duration))
                            .font(.title.monospacedDigit())
                            .foregroundStyle(recorder.isRecording ? AppTheme.danger : .primary)
                            .accessibilityLabel("已录制 \(recorder.duration, specifier: "%.1f") 秒，最长 3 秒")

                        Button {
                            if recorder.isRecording {
                                recorder.finishRecording()
                            } else {
                                Task { await recorder.startRecording() }
                            }
                        } label: {
                            Label(
                                recorder.isRecording ? "停止录音" : recorder.isRequestingPermission ? "等待麦克风授权" : recorder.hasDraft ? "重新录制" : "开始录音",
                                systemImage: recorder.isRecording ? "stop.fill" : "mic.fill"
                            )
                            .labelStyle(.titleAndIcon)
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .tint(recorder.isRecording ? AppTheme.danger : AppTheme.readablePrimary)
                        .disabled(recorder.isRequestingPermission || recorder.isFinishingRecording || (!audio.canChangeSound && !recorder.isRecording))

                        if recorder.hasDraft {
                            Button {
                                if audio.isPlaying { audio.stop() }
                                else { Task { await recorder.preview() } }
                            } label: {
                                Label(audio.isPlaying ? "停止试听" : "试听录音", systemImage: audio.isPlaying ? "stop.circle" : "play.circle")
                                    .labelStyle(.titleAndIcon)
                                    .font(.body.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(recorder.isRecording || recorder.isRequestingPermission || recorder.isFinishingRecording)
                        }

                        if let error = recorder.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(AppTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.updatesFrequently)
                        }

                        if recorder.permissionDenied {
                            Button {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            } label: {
                                Text("打开麦克风设置")
                                    .font(.body.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonBorderShape(.roundedRectangle(radius: AppLayout.controlCornerRadius))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .softPageBackground()
            .navigationTitle("自定义庆祝音效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用录音") {
                        if recorder.save() { dismiss() }
                    }
                    .disabled(!recorder.hasDraft || recorder.isRecording || recorder.isRequestingPermission || recorder.isFinishingRecording || !audio.canChangeSound)
                }
            }
            .tint(AppTheme.readablePrimary)
        }
        .onDisappear { recorder.close() }
        .onChange(of: scenePhase) { _, phase in
            // 麦克风授权弹窗会短暂进入 inactive，不能因此取消首次录音。
            if phase == .background { recorder.setAppActive(false) }
            else if phase == .active { recorder.setAppActive(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            recorder.handleInterruption()
        }
    }
}
