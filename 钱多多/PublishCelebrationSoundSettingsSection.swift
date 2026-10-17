import AVFoundation
import SwiftUI
import UIKit

struct PublishCelebrationSoundSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var audio = PublishCelebrationAudio.shared
    @State private var showingRecorder = false
    @State private var showingRestoreConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsCardSection(
            "发布庆祝音效",
            footer: "发布时遵循系统静音设置。自定义录音仅保存在本机，不会随共享或数据导出发送。"
        ) {
            HStack(spacing: 12) {
                Label("当前音效", systemImage: "waveform")
                Spacer(minLength: 8)
                Text(audio.hasCustomRecording ? "我的录音" : "默认庆祝音")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .settingsRow()

            SettingsRowDivider()

            Button {
                if audio.isPlaying {
                    audio.stop()
                } else {
                    do { try audio.previewSelected() }
                    catch { errorMessage = "无法播放音效，请重新录制或恢复默认音效。" }
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

            if audio.hasCustomRecording {
                SettingsRowDivider()

                Button {
                    showingRestoreConfirmation = true
                } label: {
                    Label("恢复默认音效", systemImage: "arrow.counterclockwise")
                        .settingsRow()
                }
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
            Button("删除录音并恢复默认", role: .destructive) {
                do { try audio.restoreDefault() }
                catch { errorMessage = "无法恢复默认音效，请稍后重试。" }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会删除本机保存的自定义录音。")
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
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(recorder.isRecording ? "正在录音" : recorder.hasDraft ? "试听你的庆祝声" : "录下你的庆祝声")
                            .font(.title2.bold())
                        Text("最长 3 秒，录好后先试听，满意再使用。")
                            .foregroundStyle(.secondary)

                        Text(String(format: "%.1f / 3.0 秒", recorder.duration))
                            .font(.title.monospacedDigit())
                            .foregroundStyle(recorder.isRecording ? Color.red : .primary)
                            .accessibilityLabel("已录制 \(recorder.duration, specifier: "%.1f") 秒，最长 3 秒")

                        Button {
                            if recorder.isRecording {
                                recorder.finishRecording()
                            } else {
                                Task { await recorder.startRecording() }
                            }
                        } label: {
                            Label(
                                recorder.isRecording ? "停止录音" : recorder.isRequestingPermission ? "正在请求麦克风权限" : recorder.hasDraft ? "重新录制" : "开始录音",
                                systemImage: recorder.isRecording ? "stop.fill" : "mic.fill"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(recorder.isRecording ? .red : AppTheme.readablePrimary)
                        .disabled(recorder.isRequestingPermission)

                        if recorder.hasDraft {
                            Button {
                                if audio.isPlaying { audio.stop() }
                                else { recorder.preview() }
                            } label: {
                                Label(audio.isPlaying ? "停止试听" : "试听录音", systemImage: audio.isPlaying ? "stop.circle" : "play.circle")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }

                        if let error = recorder.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .accessibilityAddTraits(.updatesFrequently)
                        }

                        if recorder.permissionDenied {
                            Button("打开麦克风设置") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text("只有点击“使用录音”才会替换当前音效。录音仅保存在本机。")
                }
            }
            .listStyle(.insetGrouped)
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
                    .disabled(!recorder.hasDraft || recorder.isRecording || recorder.isRequestingPermission)
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
