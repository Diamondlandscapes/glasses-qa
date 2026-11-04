import AVFoundation
import Foundation

enum SpeechRate {
    /// A little slower than the system default so short answers stay clear.
    static let normal = Double(AVSpeechUtteranceDefaultSpeechRate) * 0.9

    /// xAI TTS speed. 1.0 is normal, allowed range is 0.7...1.5.
    static func araSpeed(from speechRate: Double) -> Double {
        let ratio = speechRate / normal
        return min(1.5, max(0.7, 0.9 * ratio))
    }
}

struct SpeechItem: Equatable {
    var number: String
    var key: String
    var text: String
}

@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [SpeechItem] = []
    private var current: SpeechItem?
    private var holdingPause = false
    private var systemActive = false
    private var rate = Float(SpeechRate.normal)
    private var araSpeed = SpeechRate.araSpeed(from: SpeechRate.normal)
    private var xaiKey: String?
    private var pauseTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var audioDone: CheckedContinuation<Void, Never>?
    private var epoch = 0

    var onVoice: (@MainActor (String) -> Void)?
    var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Queues new question numbers in numeric order. Never replaces or cancels
    /// the answer that is already playing.
    func enqueue(_ items: [SpeechItem], rate: Double, xaiKey: String?) {
        prepareSession()
        self.rate = Float(min(1, max(0.05, rate)))
        self.araSpeed = SpeechRate.araSpeed(from: rate)
        self.xaiKey = xaiKey
        let taken = Set(queue.map(\.number)).union(current.map { [$0.number] } ?? [])
        for item in items where !taken.contains(item.number) {
            queue.append(item)
        }
        queue.sort { (Int($0.number) ?? Int.max) < (Int($1.number) ?? Int.max) }
        if current == nil && !holdingPause {
            pump()
        }
    }

    func stop() {
        epoch += 1
        pauseTask?.cancel()
        pauseTask = nil
        holdingPause = false
        systemActive = false
        queue.removeAll()
        current = nil
        player?.stop()
        player = nil
        resumeAudio()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        let token = epoch
        Task { await self.perform(item, token: token) }
    }

    private func perform(_ item: SpeechItem, token: Int) async {
        guard token == epoch, current?.number == item.number else { return }
        if let xaiKey, !xaiKey.isEmpty {
            do {
                let data = try await AraTTS.mpeg(text: item.text, apiKey: xaiKey, speed: araSpeed)
                guard token == epoch else { return }
                if await playMPEG(data) {
                    onVoice?("Ara")
                    await finish(token: token)
                    return
                }
            } catch {
                onVoice?("System voice")
            }
        } else {
            onVoice?("System voice")
        }
        guard token == epoch else { return }
        speakSystem(item)
    }

    private func playMPEG(_ data: Data) async -> Bool {
        prepareSession()
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        playbackOK = false
        guard player.play() else { return false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioDone = continuation
        }
        return playbackOK
    }

    private var playbackOK = false

    private func resumeAudio() {
        audioDone?.resume()
        audioDone = nil
    }

    private func speakSystem(_ item: SpeechItem) {
        onVoice?("System voice")
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.4
        systemActive = true
        synthesizer.speak(utterance)
    }

    private func finish(token: Int) async {
        guard token == epoch else { return }
        current = nil
        player = nil
        pauseTask?.cancel()
        guard !queue.isEmpty else {
            holdingPause = false
            return
        }
        holdingPause = true
        pauseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, token == self.epoch else { return }
            self.holdingPause = false
            self.pump()
        }
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothA2DP, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.systemActive else { return }
            self.systemActive = false
            let token = self.epoch
            await self.finish(token: token)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.systemActive = false
            self.current = nil
            self.holdingPause = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playbackOK = flag
            self.resumeAudio()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.playbackOK = false
            self.resumeAudio()
        }
    }
}
