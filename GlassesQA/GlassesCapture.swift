import Foundation
@preconcurrency import MWDATCamera
@preconcurrency import MWDATCore
import UIKit

enum CaptureError: LocalizedError {
    case stopped
    case notReady
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .stopped:
            return "Stopped."
        case .notReady:
            return "The camera isn't ready."
        case .timedOut:
            return "The glasses didn't send a photo in time."
        case .failed(let message):
            return message
        }
    }
}

/// Photo capture on a started device session, with a video-frame fallback.
/// API names match Meta Wearables DAT 1.0.1 (`MWDATCamera` / `MWDATCore`).
@MainActor
final class GlassesCapture {
    enum Mode: Equatable {
        case photo
        case streamFrame
    }

    private(set) var mode: Mode?
    private(set) var needsGlassesAppUpdate = false

    var onProgress: (@MainActor (Double) -> Void)?
    var onStatus: (@MainActor (String) -> Void)?
    var onSessionIssue: (@MainActor (_ message: String, _ fatal: Bool, _ needsAppUpdate: Bool) -> Void)?

    private var session: DeviceSession?
    private var camera: Camera?
    private var photo: Photo?
    private var stream: MWDATCamera.Stream?
    private var tokens: [AnyListenerToken] = []
    private var errorTask: Task<Void, Never>?
    private var epoch = 0

    private var stopped = true
    private var sessionFailed: String?
    private var photoState: PhotoState = .stopped
    private var sawPhotoStarting = false
    private var sawPhotoStarted = false
    private var photoSetupFailed = false
    private var awaitingPhoto = false
    private var pendingJPEG: Data?
    private var pendingError: String?

    private var streamReady = false
    private var streamAborted = false
    private var acceptingStreamErrors = false
    private var streamStartError: String?
    private var latestJPEG: Data?
    private var latestFrameAt: Date?
    private var lastEncoded = Date.distantPast
    private var awaitedDevice: DeviceIdentifier?

    var modeLabel: String {
        switch mode {
        case .photo:
            return "Still photo"
        case .streamFrame:
            return "Video frame"
        case nil:
            return "Camera off"
        }
    }

    func prepare(wearables: any WearablesInterface, selector: AutoDeviceSelector) async throws -> Mode {
        stop()
        let generation = epoch
        stopped = false
        needsGlassesAppUpdate = false
        sessionFailed = nil
        mode = nil

        onStatus?("Checking camera permission…")
        let allowed: Bool
        do {
            allowed = try await ensureCameraPermission(wearables)
        } catch {
            throw CaptureError.failed(GlassesDeviceReport.permissionMessage(error))
        }
        guard allowed else {
            throw CaptureError.failed("Allow camera access in Meta AI, then start again.")
        }

        onStatus?("Waiting for the glasses to be ready…")
        _ = await waitForActiveDevice(selector, seconds: 8)
        guard !stopped else { throw CaptureError.stopped }

        onStatus?("Starting the glasses session…")
        let session = try openSession(wearables: wearables, selector: selector)
        self.session = session

        errorTask = Task { [weak self] in
            for await error in session.errorStream() {
                self?.handleSessionError(error, generation: generation)
            }
        }
        await Task.yield()

        do {
            try session.start()
        } catch let error as DeviceSessionError {
            if case .noEligibleDevice = error {
                throw ineligibleError(wearables)
            }
            throw sessionError(error, wearables: wearables)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        _ = await waitUntil(seconds: 20) {
            session.state == .started || self.sessionFailed != nil || session.state == .stopped
        }
        if session.state != .started {
            throw CaptureError.failed(sessionFailed ?? "The glasses session didn't start.")
        }

        if await startPhotoWithRetry(on: session) {
            mode = .photo
            return .photo
        }

        releaseCamera()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !stopped, session.state == .started else { throw CaptureError.stopped }

        if await startStream(on: session, resolution: .medium) {
            mode = .streamFrame
            return .streamFrame
        }
        releaseCamera()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if await startStream(on: session, resolution: .low) {
            mode = .streamFrame
            return .streamFrame
        }
        throw CaptureError.failed(streamStartError ?? "Couldn't start the camera.")
    }

    func nextJPEG() async throws -> Data {
        if stopped { throw CaptureError.stopped }
        switch mode {
        case .photo:
            return try await capturePhotoJPEG()
        case .streamFrame:
            return try await grabFrameJPEG()
        case nil:
            throw CaptureError.notReady
        }
    }

    func fallBackToStream() async throws {
        guard !stopped, let session, session.state == .started else {
            throw CaptureError.notReady
        }
        releaseCamera()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !stopped else { throw CaptureError.stopped }
        if await startStream(on: session, resolution: .medium) {
            mode = .streamFrame
            return
        }
        releaseCamera()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if await startStream(on: session, resolution: .low) {
            mode = .streamFrame
            return
        }
        throw CaptureError.failed(streamStartError ?? "The video stream didn't start.")
    }

    func stop() {
        epoch += 1
        stopped = true
        awaitingPhoto = false
        acceptingStreamErrors = false
        errorTask?.cancel()
        errorTask = nil
        let camera = self.camera
        let session = self.session
        tokens.removeAll()
        photo = nil
        stream = nil
        self.camera = nil
        self.session = nil
        mode = nil
        camera?.stop()
        session?.stop()
    }

    private func ensureCameraPermission(_ wearables: any WearablesInterface) async throws -> Bool {
        var status = try await wearables.checkPermissionStatus(.camera)
        if status != .granted {
            onStatus?("Allow camera access in Meta AI…")
            status = try await wearables.requestPermission(.camera)
        }
        return status == .granted
    }

    /// `AutoDeviceSelector` only becomes eligible after it hears `devicesStream()`.
    /// Creating one and calling `createSession` in the same turn throws
    /// `DeviceSessionError.noEligibleDevice` ("No eligible device available")
    /// even when the glasses are already connected.
    private func waitForActiveDevice(_ selector: AutoDeviceSelector, seconds: TimeInterval) async -> DeviceIdentifier? {
        if let id = selector.activeDevice { return id }
        awaitedDevice = nil
        let watch = Task { @MainActor [weak self] in
            for await id in selector.activeDeviceStream() {
                if let id {
                    self?.awaitedDevice = id
                    return
                }
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && awaitedDevice == nil && !stopped {
            if let id = selector.activeDevice {
                awaitedDevice = id
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        watch.cancel()
        return awaitedDevice ?? selector.activeDevice
    }

    private func openSession(
        wearables: any WearablesInterface,
        selector: AutoDeviceSelector
    ) throws -> DeviceSession {
        if selector.activeDevice != nil {
            do {
                return try wearables.createSession(deviceSelector: selector)
            } catch let error as DeviceSessionError {
                guard case .noEligibleDevice = error else {
                    throw sessionError(error, wearables: wearables)
                }
            } catch {
                throw CaptureError.failed(error.localizedDescription)
            }
        }
        guard let id = preferredDeviceID(wearables) else {
            throw ineligibleError(wearables)
        }
        do {
            let specific = SpecificDeviceSelector(device: id)
            return try wearables.createSession(deviceSelector: specific)
        } catch let error as DeviceSessionError {
            if case .noEligibleDevice = error {
                throw ineligibleError(wearables)
            }
            throw sessionError(error, wearables: wearables)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    private func preferredDeviceID(_ wearables: any WearablesInterface) -> DeviceIdentifier? {
        let known = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        if let display = known.first(where: { $0.deviceType() == .metaRayBanDisplay && $0.linkState == .connected }) {
            return display.identifier
        }
        if let connected = known.first(where: { $0.linkState == .connected }) {
            return connected.identifier
        }
        return known.first?.identifier
    }

    private func sessionError(_ error: DeviceSessionError, wearables: any WearablesInterface) -> CaptureError {
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            needsGlassesAppUpdate = true
            return .failed("\(error.localizedDescription)\n\(GlassesDeviceReport.summary(wearables))")
        case .insufficientSDKVersion:
            return .failed("These glasses need a newer SDK than DAT 1.0.1.\n\(GlassesDeviceReport.summary(wearables))")
        default:
            return .failed(error.localizedDescription)
        }
    }

    private func ineligibleError(_ wearables: any WearablesInterface) -> CaptureError {
        let report = GlassesDeviceReport.summary(wearables)
        let known = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        if known.contains(where: { $0.compatibility() == .sdkUpdateRequired }) {
            return .failed("These glasses need a newer SDK than DAT 1.0.1, the newest published version.\n\(report)")
        }
        if known.contains(where: { $0.compatibility() == .deviceUpdateRequired }) {
            return .failed("These glasses need a firmware update before the camera can be used.\n\(report)")
        }
        if known.contains(where: { $0.hingeState == .closed || $0.donState == .doffed }) {
            return .failed("Unfold the glasses and put them on, then start again.\n\(report)")
        }
        needsGlassesAppUpdate = true
        return .failed("No eligible device for a camera session. Ray-Ban Display is supported by DAT 1.0.1. Unfold the glasses, wear them, and install the Device Access Toolkit onto the glasses from Meta AI if Developer Mode offers it.\n\(report)")
    }

    private func startPhotoWithRetry(on session: DeviceSession) async -> Bool {
        if await startPhoto(on: session) { return true }
        releaseCamera()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !stopped, session.state == .started else { return false }
        return await startPhoto(on: session)
    }

    private func startPhoto(on session: DeviceSession) async -> Bool {
        photoSetupFailed = false
        sawPhotoStarting = false
        sawPhotoStarted = false
        photoState = .stopped
        do {
            guard let camera = try session.addCamera() else {
                streamStartError = "Camera isn't available yet."
                return false
            }
            self.camera = camera
            let photo = camera.photo
            self.photo = photo

            let stateToken = photo.statePublisher.listen { [weak self] state in
                Task { [weak self] in
                    await self?.handlePhotoState(state)
                }
            }
            tokens.append(stateToken)

            let dataToken = photo.photoDataPublisher.listen { [weak self] capture in
                let bytes = capture.imageData
                Task { [weak self] in
                    await self?.handlePhotoData(bytes)
                }
            }
            tokens.append(dataToken)

            let progressToken = photo.transferProgressPublisher.listen { [weak self] progress in
                let fraction = progress.fraction
                Task { [weak self] in
                    await self?.handleProgress(fraction)
                }
            }
            tokens.append(progressToken)

            let errorToken = photo.errorPublisher.listen { [weak self] error in
                let message = error.localizedDescription
                let setupFailed: Bool
                if case .sessionSetupFailed(_) = error {
                    setupFailed = true
                } else {
                    setupFailed = false
                }
                Task { [weak self] in
                    await self?.handlePhotoFailure(message: message, setupFailed: setupFailed)
                }
            }
            tokens.append(errorToken)

            photo.start()
        } catch {
            streamStartError = error.localizedDescription
            return false
        }

        _ = await waitUntil(seconds: 8) {
            self.sawPhotoStarted || self.photoSetupFailed || self.stopped
        }
        return sawPhotoStarted && !photoSetupFailed && !stopped
    }

    private func startStream(on session: DeviceSession, resolution: StreamingResolution) async -> Bool {
        streamStartError = nil
        streamAborted = false
        streamReady = false
        acceptingStreamErrors = true
        latestJPEG = nil
        latestFrameAt = nil
        do {
            let config = StreamConfiguration(videoCodec: .raw, resolution: resolution, frameRate: 24)
            guard let camera = try session.addCamera(config: config) else {
                streamStartError = "Camera isn't available yet."
                acceptingStreamErrors = false
                return false
            }
            self.camera = camera
            let stream = camera.stream
            self.stream = stream

            let stateToken = stream.statePublisher.listen { [weak self] state in
                Task { [weak self] in
                    await self?.handleStreamState(state)
                }
            }
            tokens.append(stateToken)

            let frameToken = stream.videoFramePublisher.listen { [weak self] frame in
                Task { [weak self] in
                    await self?.handleFrame(frame)
                }
            }
            tokens.append(frameToken)

            let errorToken = stream.errorPublisher.listen { [weak self] error in
                let message = error.localizedDescription
                Task { [weak self] in
                    await self?.handleStreamFailure(message)
                }
            }
            tokens.append(errorToken)

            stream.start()
        } catch {
            streamStartError = error.localizedDescription
            acceptingStreamErrors = false
            return false
        }

        _ = await waitUntil(seconds: 12) {
            self.streamReady || self.latestJPEG != nil || self.streamAborted || self.stopped
        }
        acceptingStreamErrors = false
        if stopped { return false }
        if streamReady || latestJPEG != nil { return true }
        if streamStartError == nil {
            streamStartError = "The video stream didn't start."
        }
        return false
    }

    private func capturePhotoJPEG() async throws -> Data {
        guard !stopped else { throw CaptureError.stopped }
        guard photoState == .started, let photo else { throw CaptureError.notReady }
        pendingJPEG = nil
        pendingError = nil
        awaitingPhoto = true
        photo.capturePhoto(resolution: .full, quality: .high)

        let deadline = Date().addingTimeInterval(25)
        while pendingJPEG == nil && pendingError == nil {
            if stopped || Task.isCancelled {
                awaitingPhoto = false
                throw CaptureError.stopped
            }
            if Date() >= deadline {
                awaitingPhoto = false
                throw CaptureError.timedOut
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        awaitingPhoto = false
        if let pendingJPEG { return pendingJPEG }
        throw CaptureError.failed(pendingError ?? "The photo didn't arrive.")
    }

    private func grabFrameJPEG() async throws -> Data {
        let started = Date()
        if let jpeg = latestJPEG, let at = latestFrameAt, started.timeIntervalSince(at) < 1.2 {
            return jpeg
        }
        let baseline = latestFrameAt
        let deadline = started.addingTimeInterval(5)
        while latestJPEG == nil || latestFrameAt == baseline {
            if stopped || Task.isCancelled { throw CaptureError.stopped }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let jpeg = latestJPEG, let at = latestFrameAt, Date().timeIntervalSince(at) < 3 else {
            throw CaptureError.timedOut
        }
        return jpeg
    }

    private func releaseCamera() {
        let camera = self.camera
        tokens.removeAll()
        photo = nil
        stream = nil
        self.camera = nil
        photoState = .stopped
        sawPhotoStarting = false
        sawPhotoStarted = false
        photoSetupFailed = false
        streamReady = false
        awaitingPhoto = false
        camera?.stop()
    }

    private func handleSessionError(_ error: DeviceSessionError, generation: Int) {
        guard generation == epoch, !stopped else { return }
        let fatal: Bool
        let needsUpdate: Bool
        switch error {
        case .dwaOutOfStuRange:
            fatal = false
            needsUpdate = false
        case .datAppOnTheGlassesUpdateRequired:
            fatal = true
            needsUpdate = true
            needsGlassesAppUpdate = true
        default:
            fatal = true
            needsUpdate = false
        }
        let message = error.localizedDescription
        if fatal {
            sessionFailed = message
        }
        onSessionIssue?(message, fatal, needsUpdate)
    }

    private func handlePhotoState(_ state: PhotoState) {
        photoState = state
        switch state {
        case .starting:
            sawPhotoStarting = true
        case .started:
            sawPhotoStarted = true
        case .stopped:
            if sawPhotoStarting && !sawPhotoStarted {
                photoSetupFailed = true
            }
        case .stopping:
            break
        @unknown default:
            break
        }
    }

    private func handlePhotoData(_ bytes: Data) {
        guard awaitingPhoto else { return }
        guard UIImage(data: bytes) != nil else {
            pendingError = "Couldn't read the photo from the glasses."
            return
        }
        pendingJPEG = bytes
    }

    private func handleProgress(_ fraction: Double) {
        guard awaitingPhoto else { return }
        onProgress?(fraction)
    }

    private func handlePhotoFailure(message: String, setupFailed: Bool) {
        if setupFailed {
            photoSetupFailed = true
        }
        if awaitingPhoto {
            pendingError = message
        }
    }

    private func handleStreamState(_ state: StreamState) {
        if state == .streaming {
            streamReady = true
        }
    }

    private func handleStreamFailure(_ message: String) {
        streamStartError = message
        if acceptingStreamErrors {
            streamAborted = true
        }
    }

    private func handleFrame(_ frame: VideoFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastEncoded) > 0.45 else { return }
        guard let image = frame.makeUIImage(), let jpeg = ImageEncoder.jpeg(from: image) else { return }
        lastEncoded = now
        latestJPEG = jpeg
        latestFrameAt = now
    }

    private func waitUntil(seconds: TimeInterval, _ ready: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}
