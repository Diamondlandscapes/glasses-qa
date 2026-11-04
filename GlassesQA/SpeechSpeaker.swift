import AVFoundation
import Foundation

@MainActor
final class SpeechSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, rate: Double) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothA2DP, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(min(1, max(0, rate)))
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
