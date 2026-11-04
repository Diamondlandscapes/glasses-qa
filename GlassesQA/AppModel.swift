import Foundation
@preconcurrency import MWDATCore
import Observation
import os
import UIKit

@MainActor
@Observable
final class AppModel {
    let settings = SettingsStore()

    private(set) var sdkReady = false
    private(set) var registrationState: RegistrationState = .unavailable
    private(set) var devices: [DeviceIdentifier] = []
    var status = "Connect your glasses to get started."
    var lastError: String?
    private(set) var running = false
    private(set) var isStarting = false
    var thumbnail: UIImage?
    var lastPhotoAt: Date?
    var question = ""
    var answer = ""
    var captureModeLabel = "Camera off"
    var needsFirmwareUpdate = false
    var needsGlassesAppUpdate = false

    @ObservationIgnored private let glasses = GlassesCapture()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private let wearables: (any WearablesInterface)?
    @ObservationIgnored private let log = Logger(subsystem: "com.dustin.glassesqa", category: "app")
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    @ObservationIgnored private var lastAnsweredKey = ""
    @ObservationIgnored private var consecutiveCaptureFailures = 0
    @ObservationIgnored private var startToken = UUID()

    init(wearables: any WearablesInterface) {
        self.wearables = wearables
        sdkReady = true
        registrationState = wearables.registrationState
        devices = wearables.devices
        wireGlasses()
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                self.applyRegistration(state)
            }
        }
        deviceTask = Task {
            for await devices in wearables.devicesStream() {
                self.devices = devices
                self.watchCompatibility(devices)
            }
        }
        watchCompatibility(wearables.devices)
        if registrationState == .registered {
            status = "Registered with Meta AI."
        }
    }

    init(configureError: String) {
        wearables = nil
        sdkReady = false
        lastError = configureError
        status = "The glasses SDK didn't start."
        log.error("Wearables.configure failed: \(configureError, privacy: .public)")
    }

    var registrationLabel: String {
        switch registrationState {
        case .unavailable:
            return "Meta AI isn't available"
        case .available:
            return "Not registered"
        case .registering:
            return "Waiting for Meta AI"
        case .registered:
            return "Registered"
        }
    }

    var glassesSummary: String {
        guard let wearables else { return "Glasses SDK didn't start." }
        guard let id = devices.first, let device = wearables.deviceForIdentifier(id) else {
            if registrationState == .registered {
                return devices.isEmpty ? "Registered. Waiting for glasses…" : "Glasses found"
            }
            return "Pair the glasses in the Meta AI app first."
        }
        let link: String
        switch device.linkState {
        case .connected:
            link = "connected"
        case .connecting:
            link = "connecting"
        case .disconnected:
            link = "disconnected"
        }
        let battery = device.batteryLevel.map { " · \($0)% battery" } ?? ""
        let extra = devices.count > 1 ? " · +\(devices.count - 1) more" : ""
        return "\(device.nameOrId()) · \(link)\(battery)\(extra)"
    }

    func connect() {
        guard let wearables, registrationState != .registering else { return }
        lastError = nil
        status = "Opening Meta AI…"
        Task {
            do {
                try await wearables.startRegistration()
            } catch {
                lastError = error.localizedDescription
                status = "Registration didn't start."
                log.error("startRegistration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func disconnect() {
        haltLoop(statusText: "Disconnecting…")
        Task {
            do {
                try await wearables?.startUnregistration()
            } catch {
                lastError = error.localizedDescription
                status = "Couldn't disconnect."
            }
        }
    }

    func start() {
        guard !running, !isStarting else { return }
        guard sdkReady, let wearables else {
            lastError = "The glasses SDK didn't start."
            return
        }
        guard registrationState == .registered else {
            lastError = "Connect the glasses with Meta AI first."
            return
        }
        guard settings.hasAPIKey else {
            lastError = "Add an OpenAI API key in Settings."
            return
        }
        isStarting = true
        lastError = nil
        consecutiveCaptureFailures = 0
        let token = UUID()
        startToken = token
        status = "Starting the glasses session…"
        Task {
            do {
                let mode = try await glasses.prepare(wearables: wearables)
                guard startToken == token else { return }
                captureModeLabel = glasses.modeLabel
                running = true
                isStarting = false
                status = mode == .photo
                    ? "Watching. Next photo on the interval."
                    : "Photo capture unavailable. Using video frames."
                loopTask = Task { await self.runLoop() }
            } catch {
                guard startToken == token else { return }
                glasses.stop()
                running = false
                isStarting = false
                needsGlassesAppUpdate = glasses.needsGlassesAppUpdate
                lastError = error.localizedDescription
                status = "Couldn't start."
                log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func userStop() {
        haltLoop(statusText: "Stopped")
    }

    func dismissError() {
        lastError = nil
    }

    func playSample() {
        speaker.speak("This is how answers will sound.", rate: settings.speechRate)
    }

    func updateFirmware() {
        Task {
            do {
                try await wearables?.openFirmwareUpdate()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func updateGlassesApp() {
        Task {
            do {
                try await wearables?.openDATGlassesAppUpdate()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func handleCallback(_ url: URL) async {
        guard sdkReady, let wearables else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
            return
        }
        do {
            _ = try await wearables.handleUrl(url, onRegistrationRequest: { [weak self] request in
                Task { [weak self] in
                    do {
                        try await request.continueRegistration()
                    } catch {
                        await self?.report(error.localizedDescription)
                    }
                }
            })
            log.info("Handled Meta AI callback")
        } catch {
            report(error.localizedDescription)
            log.error("handleUrl failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func report(_ message: String) {
        lastError = message
    }

    private func wireGlasses() {
        glasses.onProgress = { [weak self] fraction in
            guard let self else { return }
            guard self.status.hasPrefix("Capturing") || self.status.hasPrefix("Receiving") else { return }
            self.status = "Receiving photo \(Int((fraction * 100).rounded()))%"
        }
        glasses.onSessionIssue = { [weak self] message, fatal, needsUpdate in
            guard let self else { return }
            if needsUpdate { self.needsGlassesAppUpdate = true }
            self.lastError = message
            if fatal && self.running {
                self.haltLoop(statusText: "Session ended")
                self.lastError = message
            }
        }
    }

    private func applyRegistration(_ state: RegistrationState) {
        registrationState = state
        guard !running, !isStarting else { return }
        switch state {
        case .registered:
            status = "Registered with Meta AI."
        case .registering:
            status = "Confirm the connection in Meta AI."
        case .available:
            status = "Not registered yet."
        case .unavailable:
            status = "Install Meta AI and turn on Developer Mode."
        }
    }

    private func watchCompatibility(_ ids: [DeviceIdentifier]) {
        guard let wearables else { return }
        let keep = Set(ids)
        compatibilityTokens = compatibilityTokens.filter { keep.contains($0.key) }
        for id in ids where compatibilityTokens[id] == nil {
            guard let device = wearables.deviceForIdentifier(id) else { continue }
            noteCompatibility(device.compatibility())
            let token = device.addCompatibilityListener { [weak self] compatibility in
                Task { [weak self] in
                    await self?.noteCompatibility(compatibility)
                }
            }
            compatibilityTokens[id] = token
        }
    }

    private func noteCompatibility(_ compatibility: Compatibility) {
        switch compatibility {
        case .deviceUpdateRequired:
            needsFirmwareUpdate = true
            lastError = "These glasses need a firmware update before the camera can be used."
        case .sdkUpdateRequired:
            lastError = "This app needs a newer glasses SDK for the connected glasses."
        case .compatible, .undefined:
            break
        }
    }

    private func runLoop() async {
        while running && !Task.isCancelled {
            let started = Date()
            await captureOnce()
            if !running || Task.isCancelled { break }
            let remaining = settings.captureInterval - Date().timeIntervalSince(started)
            if remaining > 0 {
                let deadline = Date().addingTimeInterval(remaining)
                while Date() < deadline {
                    if !running || Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    private func captureOnce() async {
        guard running else { return }
        guard settings.hasAPIKey else {
            lastError = "Add an OpenAI API key in Settings."
            haltLoop(statusText: "Stopped")
            return
        }
        status = "Capturing…"
        do {
            let jpeg = try await glasses.nextJPEG()
            guard running else { return }
            consecutiveCaptureFailures = 0
            if let image = UIImage(data: jpeg) {
                thumbnail = image
            }
            lastPhotoAt = Date()
            status = "Reading the photo…"
            let text = try await OpenAIVision.answer(
                jpeg: jpeg,
                apiKey: settings.apiKey,
                model: settings.modelName
            )
            guard running else { return }
            guard let turn = QuestionParser.parse(text) else {
                status = "No question in this photo"
                return
            }
            let key = QuestionParser.normalize(turn.question)
            if !key.isEmpty, key == lastAnsweredKey {
                status = "Same question, skipped"
                return
            }
            question = turn.question
            answer = turn.answer
            lastAnsweredKey = key
            status = "Speaking"
            let spoken = turn.answer.count > 500 ? String(turn.answer.prefix(500)) : turn.answer
            speaker.speak(spoken, rate: settings.speechRate)
        } catch is CancellationError {
            return
        } catch CaptureError.stopped {
            return
        } catch {
            guard running else { return }
            if error is VisionError {
                lastError = error.localizedDescription
                status = "OpenAI request failed"
                log.error("vision failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            consecutiveCaptureFailures += 1
            log.error("capture failed: \(error.localizedDescription, privacy: .public)")
            if glasses.mode == .photo, consecutiveCaptureFailures >= 2 {
                status = "Photo capture failed. Switching to video frames…"
                do {
                    try await glasses.fallBackToStream()
                    captureModeLabel = glasses.modeLabel
                    consecutiveCaptureFailures = 0
                    status = "Using video frames"
                } catch {
                    lastError = error.localizedDescription
                    status = "Capture failed"
                }
            } else {
                status = error.localizedDescription
            }
        }
    }

    private func haltLoop(statusText: String) {
        startToken = UUID()
        running = false
        isStarting = false
        loopTask?.cancel()
        loopTask = nil
        glasses.stop()
        speaker.stop()
        captureModeLabel = "Camera off"
        status = statusText
    }
}
