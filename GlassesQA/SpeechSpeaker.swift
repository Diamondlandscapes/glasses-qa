import AVFoundation
import Foundation

enum SpeechRate {
    /// A little slower than the system default so short answers stay clear.
    static let normal = Double(AVSpeechUtteranceDefaultSpeechRate) * 0.9
}

struct SpeechItem: Equatable {
    var number: String
    var key: String
    var text: String
}

@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [SpeechItem] = []
    private var current: SpeechItem?
    private var holdingPause = false
    private var rate = Float(SpeechRate.normal)
    private var pauseTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Adds items that are not already being spoken or queued with the same answer.
    /// A queued item for the same question is replaced when the answer changes.
    /// Speech already in progress is left alone.
    func enqueue(_ items: [SpeechItem], rate: Double) {
        prepareSession()
        self.rate = Float(min(1, max(0.05, rate)))
        for item in items {
            if let current, current.number == item.number {
                if current.key == item.key { continue }
                replaceQueued(item)
                continue
            }
            if let index = queue.firstIndex(where: { $0.number == item.number }) {
                if queue[index].key == item.key { continue }
                queue[index] = item
                continue
            }
            queue.append(item)
        }
        if current == nil && !holdingPause {
            pump()
        }
    }

    func stop() {
        pauseTask?.cancel()
        pauseTask = nil
        holdingPause = false
        queue.removeAll()
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func replaceQueued(_ item: SpeechItem) {
        if let index = queue.firstIndex(where: { $0.number == item.number }) {
            if queue[index].key != item.key {
                queue[index] = item
            }
        } else {
            queue.append(item)
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.4
        synthesizer.speak(utterance)
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
            self.current = nil
            self.holdingPause = !self.queue.isEmpty
            self.pauseTask?.cancel()
            self.pauseTask = Task { @MainActor in
                if self.holdingPause {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                guard !Task.isCancelled else { return }
                self.holdingPause = false
                self.pump()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.current = nil
            self.holdingPause = false
            self.pauseTask?.cancel()
        }
    }
}
