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
    var roundTrip: TimeInterval?
    var captureModeLabel = "Camera off"
    var needsFirmwareUpdate = false
    var needsGlassesAppUpdate = false

    @ObservationIgnored private let glasses = GlassesCapture()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private let wearables: (any WearablesInterface)?
    @ObservationIgnored private let deviceSelector: AutoDeviceSelector?
    @ObservationIgnored private let log = Logger(subsystem: "com.dustin.glassesqa", category: "app")
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    @ObservationIgnored private var lastSpoken: [String: String] = [:]
    @ObservationIgnored private var snapRequested = false
    @ObservationIgnored private var oneShot = false
    @ObservationIgnored private var consecutiveCaptureFailures = 0
    @ObservationIgnored private var startToken = UUID()
    @ObservationIgnored private var cameraAccessGranted = false
    @ObservationIgnored private var cameraPermissionAttempted = false
    @ObservationIgnored private var permissionTask: Task<Void, Never>?

    init(wearables: any WearablesInterface) {
        self.wearables = wearables
        deviceSelector = AutoDeviceSelector(wearables: wearables)
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
                self.refreshCameraPermission()
            }
        }
        watchCompatibility(wearables.devices)
        if registrationState == .registered {
            status = "Registered with Meta AI."
            refreshCameraPermission()
        }
    }

    init(configureError: String) {
        wearables = nil
        deviceSelector = nil
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
        return "\(device.nameOrId()) · \(GlassesDeviceReport.typeName(device.deviceType())) · \(link)\(battery)\(extra)"
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

    var latencyLabel: String {
        guard let roundTrip else { return "Round trip —" }
        return String(format: "Round trip %.1f s", roundTrip)
    }

    func snapNow() {
        if running || isStarting {
            snapRequested = true
            if running {
                status = "Snapping…"
            }
            return
        }
        guard sdkReady, let wearables, let deviceSelector else {
            lastError = "The glasses SDK didn't start."
            return
        }
        guard registrationState == .registered else {
            lastError = "Connect the glasses with Meta AI first."
            return
        }
        guard settings.hasAPIKey else {
            lastError = settings.missingKeyMessage
            return
        }
        oneShot = true
        isStarting = true
        lastError = nil
        let token = UUID()
        startToken = token
        status = "Snapping…"
        Task {
            do {
                _ = try await glasses.prepare(wearables: wearables, selector: deviceSelector)
                guard startToken == token else { return }
                captureModeLabel = glasses.modeLabel
                running = true
                isStarting = false
                await captureOnce()
                guard startToken == token else { return }
                endCapture(statusText: status, keepSpeaking: true)
            } catch {
                guard startToken == token else { return }
                glasses.stop()
                running = false
                isStarting = false
                oneShot = false
                needsGlassesAppUpdate = glasses.needsGlassesAppUpdate
                lastError = error.localizedDescription
                status = "Couldn't snap."
                log.error("snap failed: \(error.localizedDescription, privacy: .public)")
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
            lastError = settings.missingKeyMessage
            return
        }
        guard let deviceSelector else {
            lastError = "The glasses SDK didn't start."
            return
        }
        oneShot = false
        isStarting = true
        lastError = nil
        consecutiveCaptureFailures = 0
        let token = UUID()
        startToken = token
        status = "Checking camera permission…"
        Task {
            do {
                let mode = try await glasses.prepare(wearables: wearables, selector: deviceSelector)
                guard startToken == token else { return }
                captureModeLabel = glasses.modeLabel
                running = true
                isStarting = false
                status = mode == .photo
                    ? "Watching. Next photo as soon as the answer returns."
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
        glasses.onStatus = { [weak self] text in
            guard let self, self.isStarting || self.running else { return }
            self.status = text
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
            refreshCameraPermission()
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
            lastError = "These glasses need a newer SDK than DAT 1.0.1, the newest published version."
        case .compatible, .undefined:
            break
        @unknown default:
            break
        }
    }

    private func refreshCameraPermission() {
        guard registrationState == .registered, !cameraAccessGranted, !cameraPermissionAttempted else { return }
        guard permissionTask == nil, let wearables else { return }
        let connected = wearables.devices.contains { id in
            wearables.deviceForIdentifier(id)?.linkState == .connected
        }
        guard connected else { return }
        cameraPermissionAttempted = true
        permissionTask = Task { [weak self] in
            await self?.promptCameraPermission()
            self?.permissionTask = nil
        }
    }

    private func promptCameraPermission() async {
        guard let wearables, registrationState == .registered, !cameraAccessGranted else { return }
        guard !running, !isStarting else { return }
        status = "Checking camera permission…"
        do {
            var permission = try await wearables.checkPermissionStatus(.camera)
            if permission != .granted {
                guard !running, !isStarting else { return }
                status = "Allow camera access in Meta AI…"
                permission = try await wearables.requestPermission(.camera)
            }
            guard !running, !isStarting else { return }
            if permission == .granted {
                cameraAccessGranted = true
                status = "Camera access granted. You can start."
            } else {
                lastError = "Camera access was denied in Meta AI."
                status = "Camera access denied."
            }
        } catch {
            guard !running, !isStarting else { return }
            lastError = GlassesDeviceReport.permissionMessage(error)
            status = "Couldn't check camera permission."
            if let permission = error as? PermissionError {
                if case .noDevice = permission { cameraPermissionAttempted = false }
                if case .noDeviceWithConnection = permission { cameraPermissionAttempted = false }
            }
        }
    }

    private func runLoop() async {
        while running && !Task.isCancelled && !oneShot {
            await captureOnce()
            if !running || Task.isCancelled || oneShot { break }
            await waitMinGap()
        }
    }

    private func waitMinGap() async {
        let gap = settings.minGap
        guard gap > 0 else { return }
        let deadline = Date().addingTimeInterval(gap)
        while Date() < deadline {
            if !running || Task.isCancelled || snapRequested { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        snapRequested = false
    }

    private func captureOnce() async {
        guard running else { return }
        guard settings.hasAPIKey else {
            lastError = settings.missingKeyMessage
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
            let started = Date()
            let text: String
            switch settings.provider {
            case .grok:
                text = try await GrokVision.answer(
                    jpeg: jpeg,
                    apiKey: settings.apiKey,
                    model: settings.modelName
                )
            case .gemini:
                text = try await GeminiVision.answer(
                    jpeg: jpeg,
                    apiKey: settings.apiKey,
                    model: settings.modelName
                )
            }
            roundTrip = Date().timeIntervalSince(started)
            guard running else { return }
            guard let turn = QuestionParser.parse(text) else {
                status = "No question in this photo"
                return
            }
            question = ""
            answer = turn.display
            let fresh = QuestionParser.freshItems(previous: lastSpoken, current: turn.items)
            lastSpoken = QuestionParser.spokenKeys(turn.items)
            guard !fresh.isEmpty else {
                status = "Same answers, skipped"
                return
            }
            status = "Speaking"
            let spoken = QuestionParser.speakable(fresh)
            let clipped = spoken.count > 500 ? String(spoken.prefix(500)) : spoken
            speaker.speak(clipped, rate: settings.speechRate)
        } catch is CancellationError {
            return
        } catch CaptureError.stopped {
            return
        } catch VisionError.rateLimited {
            guard running else { return }
            status = "Rate limited, skipped"
            return
        } catch {
            guard running else { return }
            if error is VisionError {
                lastError = error.localizedDescription
                status = settings.provider == .grok ? "Grok request failed" : "Gemini request failed"
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
        endCapture(statusText: statusText, keepSpeaking: false)
    }

    private func endCapture(statusText: String, keepSpeaking: Bool) {
        startToken = UUID()
        running = false
        isStarting = false
        oneShot = false
        snapRequested = false
        loopTask?.cancel()
        loopTask = nil
        glasses.stop()
        if !keepSpeaking {
            speaker.stop()
        }
        captureModeLabel = "Camera off"
        status = statusText
    }
}
