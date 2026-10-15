import AVFoundation

@MainActor
final class DrillSound {
    static let shared = DrillSound()
    private var player: AVAudioPlayer?
    func play(_ cue: String, enabled: Bool) {
        guard enabled, let url = Bundle.main.url(forResource: "drill-\(cue)", withExtension: "wav") else { return }
        // Ambient respects the hardware silent switch and other audio.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.45
        player?.play()
    }
}
