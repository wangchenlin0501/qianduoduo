//
//  PublishCelebrationView.swift
//  钱多多
//

import AVFoundation
import SwiftUI

struct PublishCelebrationOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false

    let onFinished: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(colorScheme == .dark ? 0.22 : 0.05)
                .ignoresSafeArea()
                .onTapGesture(perform: onFinished)

            VStack(spacing: 0) {
                CatClapCelebration()
                    .frame(width: 330, height: 270)

                Text("发布成功")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.primary)
                    .shadow(color: textGlow, radius: 8, x: 0, y: 1)

            }
            .scaleEffect(isVisible ? 1 : 0.88)
            .opacity(isVisible ? 1 : 0)
            .offset(y: -10)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .task {
            PublishCelebrationEffects.shared.play()

            withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) {
                isVisible = true
            }

            let displaySeconds = PublishCelebrationClip.duration + 0.35
            try? await Task.sleep(nanoseconds: UInt64(displaySeconds * 1_000_000_000))
            onFinished()
        }
    }

    private var textGlow: Color {
        colorScheme == .dark ? .black.opacity(0.55) : .white.opacity(0.9)
    }
}

@MainActor
private final class PublishCelebrationEffects {
    static let shared = PublishCelebrationEffects()

    private var player: AVAudioPlayer?
    private let successFeedback = UINotificationFeedbackGenerator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .soft)

    func play() {
        successFeedback.prepare()
        impactFeedback.prepare()
        playSound()

        successFeedback.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            impactFeedback.impactOccurred(intensity: 0.55)
        }
    }

    private func playSound() {
        guard let url = Bundle.main.url(forResource: "PublishCelebrationSound", withExtension: "m4a") else {
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
        } catch {
            player = nil
        }
    }
}

private struct CatClapCelebration: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var frameIndex = 0
    @State private var isReady = false

    var body: some View {
        ZStack {
            Image(uiImage: currentImage)
                .resizable()
                .scaledToFit()
                .frame(width: 330, height: 255)
                .scaleEffect(isReady ? 1 : 0.9, anchor: .bottom)
                .opacity(isReady ? 1 : 0)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.1), radius: 14, x: 0, y: 8)
        }
        .task {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                isReady = true
            }

            guard !PublishCelebrationClip.frames.isEmpty else { return }
            frameIndex = 0

            for index in PublishCelebrationClip.frames.indices {
                if Task.isCancelled { return }
                frameIndex = index
                try? await Task.sleep(nanoseconds: PublishCelebrationClip.frameNanoseconds)
            }
        }
    }

    private var currentImage: UIImage {
        if PublishCelebrationClip.frames.indices.contains(frameIndex) {
            return PublishCelebrationClip.frames[frameIndex]
        }
        return UIImage(named: "PublishCelebrationCat") ?? UIImage()
    }
}

private enum PublishCelebrationClip {
    static let frameCount = 45
    static let framesPerSecond = 15.0
    static let frameNanoseconds = UInt64((1.0 / framesPerSecond) * 1_000_000_000)
    static let duration = Double(frameCount) / framesPerSecond

    static let frames: [UIImage] = (0..<frameCount).compactMap { index in
        let name = String(format: "celebration_%03d", index)
        if let image = UIImage(named: name) {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "PublishCelebrationFrames") {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }
}
