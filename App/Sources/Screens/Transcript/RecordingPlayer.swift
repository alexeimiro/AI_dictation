@preconcurrency import AVFoundation
import MurmurUI
import Observation
import SwiftUI

/// Plays a dictation's kept recording on its transcript page.
@MainActor
@Observable
final class RecordingPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Murmur's own session holds the audio session; otherwise playback sets it up and lets go after.
    @ObservationIgnored private var ownsAudioSession = false

    func load(_ url: URL) {
        guard player?.url != url else { return }
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    var isLoaded: Bool { player != nil }

    /// `sessionIsLive`: Murmur's microphone session is on, and its audio session already plays
    /// through the speaker.
    func toggle(sessionIsLive: Bool) {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            finish(keepPosition: true)
            return
        }
        if !sessionIsLive {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playback, mode: .spokenAudio)
            try? audio.setActive(true)
            ownsAudioSession = true
        }
        let delegate = Delegate { [weak self] in
            Task { @MainActor in self?.finish(keepPosition: false) }
        }
        self.delegate = delegate
        player.delegate = delegate
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    func stop() {
        player?.stop()
        finish(keepPosition: false)
    }

    private func finish(keepPosition: Bool) {
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        if keepPosition {
            currentTime = player?.currentTime ?? 0
        } else {
            player?.currentTime = 0
            currentTime = 0
        }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private final class Delegate: NSObject, AVAudioPlayerDelegate {
        let onFinish: @Sendable () -> Void
        init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    }
}

/// ▶︎ with a progress bar and the time, Wispr Flow's audio row on a transcript.
struct RecordingPlayerRow: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @State private var player = RecordingPlayer()

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle(sessionIsLive: model.session.isLive)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Palette.ink, in: .circle)
            }
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.canvas)
                        Capsule().fill(Palette.ink).frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                Text("\(Self.time(player.currentTime)) / \(Self.time(player.duration))")
                    .font(.ui(13).monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(14)
        .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
        .onAppear { player.load(url) }
        .onDisappear { player.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording")
    }

    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
