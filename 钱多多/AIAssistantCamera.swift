//
//  AIAssistantCamera.swift
//  钱多多
//

@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Inline (non-fullscreen) camera used by the assistant composer.
final class AIAssistantCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum State { case starting, running, denied, unavailable }

    @Published var state: State = .starting
    @Published var isCapturing = false

    nonisolated let session = AVCaptureSession()
    nonisolated private let output = AVCapturePhotoOutput()
    nonisolated private let queue = DispatchQueue(label: "qianduoduo.assistant.camera")
    private var position: AVCaptureDevice.Position = .back
    var onPhoto: ((UIImage) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.configureAndRun() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func flip() {
        position = position == .back ? .front : .back
        configureAndRun()
    }

    func capture() {
        guard state == .running, !isCapturing else { return }
        isCapturing = true
        let output = output
        queue.async {
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func configureAndRun() {
        let session = session
        let output = output
        let position = position
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.inputs.forEach { session.removeInput($0) }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                Task { @MainActor in self.state = .unavailable }
                return
            }
            session.addInput(input)
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self.state = .running }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            self.isCapturing = false
            if let image { self.onPhoto?(image) }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct AIAssistantCameraCard: View {
    let onCapture: (UIImage) -> Void
    let onClose: () -> Void
    var captured: [UIImage] = []
    var canCaptureMore = true

    @StateObject private var camera = AIAssistantCameraController()

    var body: some View {
        ZStack {
            Color.black
            switch camera.state {
            case .running, .starting:
                CameraPreview(session: camera.session)
            case .denied:
                message("需要相机权限才能拍照", action: "去设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .unavailable:
                message("这台设备的相机暂时不可用", action: nil, perform: {})
            }
        }
        .overlay(alignment: .bottom) { controls }
        .overlay(alignment: .topLeading) {
            if !captured.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(captured.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                    }
                }
                .padding(16)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: captured.count)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
        .onAppear {
            camera.onPhoto = onCapture
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    private var controls: some View {
        HStack {
            if captured.isEmpty {
                roundButton("chevron.left", label: "关闭相机", action: onClose)
            } else {
                Button(action: onClose) {
                    Text("完成 \(captured.count)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(height: 52)
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(.white))
                }
                .accessibilityLabel("完成拍照")
            }
            Spacer()
            Button {
                camera.capture()
            } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle().fill(.white)
                        .frame(width: 62, height: 62)
                        .scaleEffect(camera.isCapturing ? 0.85 : 1)
                }
            }
            .disabled(camera.state != .running || !canCaptureMore)
            .opacity(canCaptureMore ? 1 : 0.4)
            .accessibilityLabel("拍照")
            Spacer()
            roundButton("arrow.triangle.2.circlepath.camera", label: "切换镜头") { camera.flip() }
                .disabled(camera.state != .running)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .animation(.easeOut(duration: 0.12), value: camera.isCapturing)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .accessibilityLabel(label)
    }

    private func message(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .foregroundStyle(.white)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.bottom, 80)
    }
}
