import AVFoundation
import Observation
import SwiftUI

@Observable @MainActor
final class PlayerModel {
    let player: AVPlayer
    var isPlaying = false
    var current: Double = 0
    var duration: Double = 0
    var rate: Float = 1.0
    var isScrubbing = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)
        try? AVAudioSession.sharedInstance().setCategory(.playback)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.current = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player.seek(to: .zero)
                Haptics.tap()
            }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.rate = rate }
        isPlaying.toggle()
        Haptics.medium()
    }

    func skip(_ seconds: Double) {
        seek(to: min(max(current + seconds, 0), duration))
        Haptics.tap()
    }

    func seek(to seconds: Double) {
        current = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
        Haptics.select()
    }
}

/// Bare AVPlayerLayer so we can draw our own controls instead of the system ones.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}
}

struct MediaPlayerView: View {
    let kind: MediaKind
    @State private var model: PlayerModel

    init(url: URL, kind: MediaKind) {
        self.kind = kind
        _model = State(initialValue: PlayerModel(url: url))
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if kind == .video {
                    PlayerLayerView(player: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { model.toggle() }
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 64))
                        .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            controls
        }
        .onDisappear { model.teardown() }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { model.current }, set: { model.current = $0 }),
                   in: 0...max(model.duration, 0.1)) { editing in
                model.isScrubbing = editing
                if !editing { model.seek(to: model.current) }
                Haptics.select()
            }
            HStack {
                Text(format(model.current)); Spacer(); Text("-" + format(max(model.duration - model.current, 0)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            HStack(spacing: 28) {
                Menu {
                    ForEach([0.5, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                        Button("\(r.formatted())×") { model.setRate(r) }
                    }
                } label: { Text("\(model.rate.formatted())×").font(.callout.bold()).frame(width: 44) }

                Button { model.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button { model.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52))
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { model.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).frame(width: 44)
            }
        }
        .padding(.horizontal, 4)
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
