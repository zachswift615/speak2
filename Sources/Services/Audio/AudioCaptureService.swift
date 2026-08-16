import AVFoundation
import Foundation
import os

private let captureLog = Logger(subsystem: "com.speak2", category: "AudioCapture")

enum AudioCaptureError: LocalizedError, Sendable, Equatable {
    case microphoneAccessDenied
    case invalidInputFormat(String)
    case unsupportedInputFormat(String)
    case inputFormatChanged(expected: String, actual: String)
    case conversionFailed(String)
    case engineStartFailed(String)
    case audioEngineException(String)
    /// The start was superseded by a newer start or a stop before it finished (e.g. a very quick key tap).
    case superseded

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .invalidInputFormat(let format):
            return "No usable microphone input (\(format)). If you're using a Bluetooth headset, wait a moment and try again, or check the input device in System Settings → Sound."
        case .unsupportedInputFormat(let format):
            return "The microphone's audio format is not supported (\(format))."
        case .inputFormatChanged(let expected, let actual):
            return "Microphone format changed mid-capture (expected \(expected), got \(actual))."
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .engineStartFailed(let reason):
            return "Could not start the microphone: \(reason)"
        case .audioEngineException(let reason):
            return "The audio engine reported an error: \(reason)"
        case .superseded:
            return "Recording was stopped before the microphone finished starting."
        }
    }
}

/// Opaque handle for one capture session. `stop(_:)` with a stale token is a no-op, so a caller that
/// was superseded (e.g. a start that resumed after a newer start) can never tear down another session.
struct AudioCaptureToken: Sendable, Equatable {
    fileprivate let id: UUID
}

/// Summary of one capture session, useful for diagnostics and user-facing errors.
struct AudioCaptureSessionReport: Sendable {
    /// Human-readable description of the input format at session start (e.g. "2 ch, 48000 Hz").
    var initialInputFormat: String
    /// Name of the input device the session (last) recorded from, e.g. "MacBook Pro Microphone".
    var inputDeviceName: String = "Unknown input"
    /// True if the user's preferred device wasn't available and the system default was used instead.
    var usedFallbackDevice: Bool = false
    /// Total 16 kHz samples handed to the sample handler.
    var samplesDelivered: Int
    /// Number of times the engine was rebuilt because the audio hardware configuration changed.
    var restarts: Int
    /// Samples delivered before the first audible buffer; -1 if the whole session was silent.
    var leadingSilentSamples: Int = -1
    /// False if every sample in the session was exact digital zero — a live microphone always has a
    /// noise floor, so this means the input device delivered no signal at all (e.g. a virtual device).
    var heardAudio: Bool = false
    /// Set when the engine could not be (re)started and capture ended early.
    var failure: AudioCaptureError?
}

/// The single owner of microphone capture for the app. Every transcription engine gets its audio here.
///
/// Delivers 16 kHz mono Float32 samples and is designed to survive the situations that used to break
/// dictation silently or crash the app:
///
/// - **Bluetooth headsets (AirPods etc.)** switch to their microphone profile when capture starts,
///   changing the input device's sample rate. `AVAudioEngine` reacts by stopping itself and posting
///   `AVAudioEngineConfigurationChange`; if nobody handles that, capture just stops. This service
///   handles it by discarding the engine and building a fresh one against the new hardware format.
/// - **Stale / invalid formats.** Installing a tap with a 0 Hz / 0-channel format, or with a format that
///   no longer matches the hardware, makes AVFAudio raise an NSException that Swift can't catch — the
///   process dies. Formats are validated before use, engine setup runs inside `withObjCExceptionsCaught`,
///   and every restart uses a brand-new engine so it never sees a stale format.
/// - **Microphone permission** is checked/requested explicitly instead of relying on the engine to
///   quietly deliver silence when access was denied.
///
/// The sample handler is invoked on the audio tap thread; keep it cheap and thread-safe
/// (e.g. append to an `AudioSampleBuffer`).
actor AudioCaptureService {
    static let shared = AudioCaptureService()

    typealias SampleHandler = @Sendable ([Float]) -> Void

    /// Tap buffer size in hardware frames (~85 ms at 48 kHz, ~170 ms at 24 kHz Bluetooth).
    private let tapBufferSize: AVAudioFrameCount = 4096
    /// How many times to retry engine setup when the input format is invalid or the engine throws.
    /// Bluetooth inputs can take a moment to become available after they're selected.
    private let maxStartAttempts = 6
    private let startRetryDelay: Duration = .milliseconds(150)
    /// Grace period after a configuration-change notification before rebuilding, so Core Audio has
    /// finished switching devices and reports the new format.
    private let configurationChangeSettleDelay: Duration = .milliseconds(150)

    private final class Session {
        let id = UUID()
        let onSamples: SampleHandler
        let onMicrophoneLive: (@Sendable () -> Void)?
        let microphoneLiveReported = OSAllocatedUnfairLock(initialState: false)
        let sampleCounter = OSAllocatedUnfairLock(initialState: 0)
        /// Samples delivered before the first non-silent buffer (-1 until audio has been heard).
        /// Bluetooth headsets often deliver zeros for a while after start while their mic link comes up.
        let leadingSilentSamples = OSAllocatedUnfairLock(initialState: -1)
        let heardAudio = OSAllocatedUnfairLock(initialState: false)
        var engine: AVAudioEngine?
        /// UID of the explicitly selected device the engine was built for (nil = system default).
        var engineDeviceUID: String?
        var configurationObserver: NSObjectProtocol?
        var watchdog: Task<Void, Never>?
        /// True while startEngine is running (initial start or a rebuild) — prevents concurrent rebuilds.
        var isStarting = false
        /// Consecutive failed rebuilds, used to back off the watchdog.
        var consecutiveFailures = 0
        var report: AudioCaptureSessionReport

        init(onSamples: @escaping SampleHandler, onMicrophoneLive: (@Sendable () -> Void)?) {
            self.onSamples = onSamples
            self.onMicrophoneLive = onMicrophoneLive
            self.report = AudioCaptureSessionReport(
                initialInputFormat: "unknown", samplesDelivered: 0, restarts: 0, failure: nil
            )
        }
    }

    private var session: Session?
    /// Report for the most recently finished session.
    private(set) var lastSessionReport: AudioCaptureSessionReport?

    /// A running engine kept alive after a session ended so the next dictation starts instantly
    /// (see `AudioInputPreference.keepWarmSeconds`). Discarded on expiry, configuration change,
    /// or when the microphone preference no longer matches.
    private struct WarmEngine {
        let engine: AVAudioEngine
        let deviceUID: String?
        let deviceName: String
        let usedFallbackDevice: Bool
        let observer: NSObjectProtocol
        let expiry: Task<Void, Never>
    }
    private var warmEngine: WarmEngine?

    /// Injectable so tests can simulate permission states without touching TCC.
    private let permissionProvider: MicrophonePermissionProviding

    init(permissionProvider: MicrophonePermissionProviding = SystemMicrophonePermissionProvider()) {
        self.permissionProvider = permissionProvider
    }

    var isCapturing: Bool { session != nil }

    /// If a device delivers only digital silence for this long after start, report it live anyway so
    /// callers waiting for "microphone ready" aren't stuck on a dead virtual input. Generous on purpose:
    /// AirPods were measured delivering exact zeros for ~1.8 s after start, and reporting "live" before
    /// then clips the user's first word.
    private let silentLiveFallbackSamples = 64_000   // 4 s at 16 kHz

    /// Start delivering 16 kHz mono samples to `onSamples`. Any session already running is stopped first.
    /// Returns a token that must be passed to `stop(_:)`.
    ///
    /// - Parameter onMicrophoneLive: Called once (from the audio thread) when the microphone is really
    ///   delivering audio: the first buffer containing a non-zero sample. A live microphone always has a
    ///   noise floor, whereas Bluetooth headsets deliver exact zeros while their mic link is still coming
    ///   up — so this fires when the user can actually be heard, not merely when the engine started.
    @discardableResult
    func start(
        onSamples: @escaping SampleHandler,
        onMicrophoneLive: (@Sendable () -> Void)? = nil
    ) async throws -> AudioCaptureToken {
        try await ensureMicrophoneAccess()

        // Re-check after the permission await: another start() may have run while we were suspended.
        if let existing = session {
            captureLog.warning("start() called while capturing — stopping previous session")
            finish(existing)
        }

        let newSession = Session(onSamples: onSamples, onMicrophoneLive: onMicrophoneLive)
        session = newSession
        newSession.isStarting = true
        defer { newSession.isStarting = false }
        do {
            if !adoptWarmEngine(for: newSession) {
                try await startEngine(for: newSession, isRestart: false)
            }
        } catch {
            newSession.report.failure = error as? AudioCaptureError
                ?? .engineStartFailed(error.localizedDescription)
            if session === newSession {
                finish(newSession)
            }
            throw error
        }
        return AudioCaptureToken(id: newSession.id)
    }

    /// Stop the session identified by `token` and return its report. A stale token (its session was
    /// already stopped or superseded) is a no-op and returns that session's report if it was the last one.
    @discardableResult
    func stop(_ token: AudioCaptureToken) -> AudioCaptureSessionReport? {
        guard let current = session, current.id == token.id else {
            return lastSessionReport // stale token: nothing to stop
        }
        finish(current)
        return current.report
    }

    /// Stop whatever session is running and release any warm standby engine (app shutdown, model
    /// unload). Prefer `stop(_:)` for ending a recording.
    func stopAll() {
        if let current = session { finish(current) }
        discardWarmEngine()
    }

    // MARK: - Warm standby

    /// After a session ends, keep its engine running (tap removed) for the configured window so the
    /// next start skips device bring-up. Returns false if keep-warm is off or the engine isn't healthy.
    private func parkEngineWarm(from current: Session) -> Bool {
        let seconds = AudioInputPreference.keepWarmSeconds
        guard seconds > 0, let engine = current.engine, engine.isRunning, current.report.failure == nil,
              let observer = current.configurationObserver else {
            return false
        }
        discardWarmEngine()
        current.watchdog?.cancel()
        current.watchdog = nil
        // Detach the tap but keep the engine (and its configuration-change observer) alive.
        _ = try? withObjCExceptionsCaught { engine.inputNode.removeTap(onBus: 0) }
        current.engine = nil
        current.configurationObserver = nil

        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.expireWarmEngine(engine)
        }
        warmEngine = WarmEngine(
            engine: engine,
            deviceUID: current.engineDeviceUID,
            deviceName: current.report.inputDeviceName,
            usedFallbackDevice: current.report.usedFallbackDevice,
            observer: observer,
            expiry: expiry
        )
        captureLog.info("Microphone kept warm for \(seconds) s")
        return true
    }

    /// Reuse the warm engine for `session` if it's still running and still matches the user's
    /// microphone preference. Returns false (and discards the warm engine) otherwise.
    private func adoptWarmEngine(for session: Session) -> Bool {
        guard let warm = warmEngine else { return false }
        let preferredUID = AudioInputPreference.savedUID
        let (device, usedFallback) = AudioInputDevices.resolvePreferred(uid: preferredUID)
        let wantedUID = preferredUID != nil && !usedFallback ? device?.uid : nil
        guard warm.engine.isRunning, warm.deviceUID == wantedUID else {
            captureLog.info("Warm engine unusable (running: \(warm.engine.isRunning), device changed: \(warm.deviceUID != wantedUID)) — cold start")
            discardWarmEngine()
            return false
        }

        let engine = warm.engine
        do {
            let format = try withObjCExceptionsCaught { () throws -> AVAudioFormat in
                let inputNode = engine.inputNode
                let format = inputNode.inputFormat(forBus: 0)
                try AudioResampler.validate(format)
                try installTap(on: inputNode, format: format, for: session)
                return format
            }
            // Hand the engine and its observer over to the session; re-key the observer to the session.
            NotificationCenter.default.removeObserver(warm.observer)
            warm.expiry.cancel()
            warmEngine = nil
            session.engine = engine
            session.engineDeviceUID = warm.deviceUID
            session.configurationObserver = observeConfigurationChanges(of: engine, sessionID: session.id)
            session.watchdog = makeWatchdog(sessionID: session.id)
            session.report.inputDeviceName = warm.deviceName
            session.report.usedFallbackDevice = warm.usedFallbackDevice
            session.report.initialInputFormat = AudioCaptureService.describe(format)
            captureLog.info("Capture started instantly from warm engine (\(AudioCaptureService.describe(format), privacy: .public) from \(warm.deviceName, privacy: .public))")
            return true
        } catch {
            captureLog.warning("Could not reuse warm engine: \(error.localizedDescription) — cold start")
            discardWarmEngine()
            return false
        }
    }

    private func expireWarmEngine(_ engine: AVAudioEngine) {
        guard let warm = warmEngine, warm.engine === engine else { return }
        captureLog.info("Warm microphone window ended — releasing engine")
        discardWarmEngine()
    }

    private func discardWarmEngine() {
        guard let warm = warmEngine else { return }
        warmEngine = nil
        warm.expiry.cancel()
        NotificationCenter.default.removeObserver(warm.observer)
        _ = try? withObjCExceptionsCaught {
            warm.engine.inputNode.removeTap(onBus: 0)
            warm.engine.stop()
        }
    }

    /// Tear the session down, record its report, and clear it as the current session.
    private func finish(_ current: Session) {
        if !parkEngineWarm(from: current) {
            teardown(current)
        }
        current.report.samplesDelivered = current.sampleCounter.withLock { $0 }
        current.report.leadingSilentSamples = current.leadingSilentSamples.withLock { $0 }
        current.report.heardAudio = current.heardAudio.withLock { $0 }
        lastSessionReport = current.report
        if session === current { session = nil }
        captureLog.info("Capture stopped: \(current.report.samplesDelivered) samples, \(current.report.restarts) restarts, leading silence \(current.report.leadingSilentSamples) samples, heard audio: \(current.report.heardAudio)")
    }

    // MARK: - Permission

    private func ensureMicrophoneAccess() async throws {
        switch permissionProvider.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            guard await permissionProvider.requestAccess() else {
                throw AudioCaptureError.microphoneAccessDenied
            }
        case .denied, .restricted:
            throw AudioCaptureError.microphoneAccessDenied
        @unknown default:
            return
        }
    }

    // MARK: - Engine lifecycle

    /// Build a fresh engine for `session`, install the tap, and start it — retrying briefly while the
    /// input isn't ready. Never reuses an engine: after a configuration change the old engine's cached
    /// input format can be stale, and a stale tap format is exactly what AVFAudio asserts on.
    private func startEngine(for session: Session, isRestart: Bool) async throws {
        var lastError: Error = AudioCaptureError.engineStartFailed("unknown")

        for attempt in 1...maxStartAttempts {
            // The session was stopped (or superseded) while we were waiting to retry.
            guard self.session === session else { throw AudioCaptureError.superseded }

            do {
                let attemptStart = CFAbsoluteTimeGetCurrent()
                var engineStartSeconds = 0.0
                let engine = AVAudioEngine()

                // Which microphone: the user's explicit choice if it's connected; otherwise leave the
                // engine on the system default (nil = don't touch device selection at all).
                let preferredUID = AudioInputPreference.savedUID
                let (device, usedFallback) = AudioInputDevices.resolvePreferred(uid: preferredUID)
                let explicitDevice = preferredUID != nil && !usedFallback ? device : nil
                if usedFallback {
                    captureLog.warning("Preferred input device not available — using system default")
                }

                // Observe configuration changes *before* starting: with a Bluetooth headset the change
                // can fire while start() is still activating the microphone, and a notification that
                // arrives before we're listening would leave a stopped engine and silent capture.
                let sessionID = session.id
                let observer = observeConfigurationChanges(of: engine, sessionID: sessionID)

                let format: AVAudioFormat
                do {
                    format = try withObjCExceptionsCaught { () throws -> AVAudioFormat in
                        let inputNode = engine.inputNode
                        if let explicitDevice {
                            try AudioCaptureService.select(explicitDevice, on: inputNode)
                        }
                        // Use the hardware-side format for the tap. The node's outputFormat is cached
                        // when the node is created and goes stale after a device change (verified:
                        // a tap installed with the stale format either never fires or trips AVFAudio's
                        // format assertion).
                        let format = inputNode.inputFormat(forBus: 0)
                        try AudioResampler.validate(format)

                        try installTap(on: inputNode, format: format, for: session)

                        engine.prepare()
                        do {
                            let t = CFAbsoluteTimeGetCurrent()
                            try engine.start()
                            engineStartSeconds = CFAbsoluteTimeGetCurrent() - t
                        } catch {
                            inputNode.removeTap(onBus: 0)
                            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
                        }
                        return format
                    }
                } catch {
                    NotificationCenter.default.removeObserver(observer)
                    throw error
                }

                session.engine = engine
                session.engineDeviceUID = explicitDevice?.uid
                session.configurationObserver = observer
                if session.watchdog == nil {
                    session.watchdog = makeWatchdog(sessionID: sessionID)
                }

                session.report.inputDeviceName = device?.name ?? "System default input"
                session.report.usedFallbackDevice = usedFallback
                let description = "\(AudioCaptureService.describe(format)) from \(device?.name ?? "system default")\(explicitDevice == nil ? " (system default)" : " (selected)")"
                let timing = String(
                    format: "%.0f ms total, engine.start %.0f ms",
                    (CFAbsoluteTimeGetCurrent() - attemptStart) * 1000, engineStartSeconds * 1000
                )
                if isRestart {
                    session.report.restarts += 1
                    captureLog.info("Capture restarted (\(session.report.restarts)) with input format \(description, privacy: .public) in \(timing, privacy: .public)")
                } else {
                    session.report.initialInputFormat = description
                    captureLog.info("Capture started with input format \(description, privacy: .public) (attempt \(attempt)) in \(timing, privacy: .public)")
                }
                return
            } catch let error as ObjCExceptionError {
                lastError = AudioCaptureError.audioEngineException(error.localizedDescription)
            } catch {
                lastError = error
            }

            captureLog.warning("Engine start attempt \(attempt)/\(self.maxStartAttempts) failed: \(lastError.localizedDescription)")
            // Invalid formats and AVFAudio assertions are transient while a device is switching; a
            // start() error from the HAL usually isn't, so give it only a couple of tries.
            let isTransient: Bool
            switch lastError as? AudioCaptureError {
            case .invalidInputFormat, .audioEngineException: isTransient = true
            default: isTransient = attempt < 2
            }
            guard isTransient, attempt < maxStartAttempts else { break }
            try? await Task.sleep(for: startRetryDelay)
        }
        throw lastError
    }

    /// Observe configuration changes of `engine` on behalf of `sessionID` (or, when the engine is a warm
    /// standby, discard it — a stopped standby engine is worthless and would only be stale later).
    private func observeConfigurationChanges(of engine: AVAudioEngine, sessionID: UUID) -> NSObjectProtocol {
        let engineID = ObjectIdentifier(engine)
        return NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange(sessionID: sessionID, engineID: engineID) }
        }
    }

    /// Install the resampling tap that feeds `session`. Must run inside `withObjCExceptionsCaught`.
    private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, for session: Session) throws {
        let resampler = try AudioResampler(inputFormat: format)
        let onSamples = session.onSamples
        let counter = session.sampleCounter
        let leadingSilence = session.leadingSilentSamples
        let heardAudio = session.heardAudio
        let liveReported = session.microphoneLiveReported
        let onMicrophoneLive = session.onMicrophoneLive
        let fallbackSamples = silentLiveFallbackSamples
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            do {
                let samples = try resampler.resample(buffer)
                guard !samples.isEmpty else { return }
                let total = counter.withLock { $0 += samples.count; return $0 }

                // Detect the moment the microphone is genuinely live (see start(onSamples:onMicrophoneLive:)).
                if !heardAudio.withLock({ $0 }) {
                    let audible = samples.contains { $0 != 0 }
                    if audible { heardAudio.withLock { $0 = true } }
                    if leadingSilence.withLock({ $0 < 0 }), audible || total >= fallbackSamples {
                        let leading = total - samples.count
                        leadingSilence.withLock { $0 = leading }
                        captureLog.info("Microphone live after \(Int(Double(leading) / 16.0)) ms\(audible ? "" : " (silent-input fallback)")")
                        let first = liveReported.withLock { was -> Bool in
                            let first = !was; was = true; return first
                        }
                        if first { onMicrophoneLive?() }
                    }
                }
                onSamples(samples)
            } catch {
                // A mismatched buffer during a device switch; the restart path replaces the tap.
                captureLog.debug("Dropped tap buffer: \(error.localizedDescription)")
            }
        }
    }

    /// Called when Core Audio reports that the input hardware changed (device switch, sample-rate or
    /// channel-count change — e.g. AirPods activating their microphone). The engine has already stopped
    /// itself at this point; rebuild it so samples keep flowing into the same session.
    ///
    /// `engineID` identifies the engine the notification came from, so a late notification from an
    /// engine we've already discarded can't tear down its replacement.
    private func handleConfigurationChange(sessionID: UUID, engineID: ObjectIdentifier?) async {
        // A warm standby engine whose hardware changed is simply dropped.
        if let warm = warmEngine, ObjectIdentifier(warm.engine) == engineID, !warm.engine.isRunning {
            captureLog.info("Audio configuration changed while microphone was warm — releasing engine")
            discardWarmEngine()
            return
        }
        guard let current = session, current.id == sessionID, !current.isStarting else { return }
        if let engineID, let engine = current.engine, ObjectIdentifier(engine) != engineID { return }
        // A genuine hardware change stops the engine before the notification is posted. With an
        // explicitly selected input device the engine also posts a spurious notification right after
        // start (its cached node format disagrees with the hardware) while happily running — tearing
        // it down would loop forever, so only rebuild when the engine really has stopped.
        if engineID != nil, let engine = current.engine, engine.isRunning {
            captureLog.debug("Ignoring configuration-change notification: engine still running")
            return
        }
        captureLog.info("Audio configuration changed — rebuilding capture engine")

        current.isStarting = true
        defer { current.isStarting = false }

        detachEngine(from: current)
        try? await Task.sleep(for: configurationChangeSettleDelay)
        guard let stillCurrent = session, stillCurrent.id == sessionID else { return }

        do {
            try await startEngine(for: stillCurrent, isRestart: true)
            stillCurrent.report.failure = nil
            stillCurrent.consecutiveFailures = 0
        } catch {
            let failure = error as? AudioCaptureError ?? .engineStartFailed(error.localizedDescription)
            stillCurrent.report.failure = failure
            stillCurrent.consecutiveFailures += 1
            captureLog.error("Could not restart capture after configuration change: \(failure.localizedDescription)")
        }
    }

    /// Safety net for the notification path: if the engine is ever found stopped while the session is
    /// live (a missed notification, a device that vanished without one, a rebuild that ran out of
    /// retries while the headset was still connecting), rebuild it.
    private func makeWatchdog(sessionID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Back off (1 s → 8 s) while rebuilds keep failing so a dead input doesn't spin.
                let failures = await self.consecutiveFailures(sessionID: sessionID)
                try? await Task.sleep(for: .seconds(min(8, 1 << min(failures, 3))))
                guard !Task.isCancelled else { return }
                await self.watchdogTick(sessionID: sessionID)
            }
        }
    }

    private func consecutiveFailures(sessionID: UUID) -> Int {
        guard let current = session, current.id == sessionID else { return 0 }
        return current.consecutiveFailures
    }

    private func watchdogTick(sessionID: UUID) async {
        guard let current = session, current.id == sessionID, !current.isStarting else { return }
        if let engine = current.engine, engine.isRunning { return }
        // Either the engine stopped without telling us, or an earlier rebuild gave up — try again.
        captureLog.warning("Watchdog: capture engine is not running — rebuilding")
        await handleConfigurationChange(sessionID: sessionID, engineID: nil)
    }

    private func detachEngine(from session: Session) {
        if let observer = session.configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            session.configurationObserver = nil
        }
        if let engine = session.engine {
            _ = try? withObjCExceptionsCaught {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            session.engine = nil
        }
    }

    private func teardown(_ session: Session) {
        session.watchdog?.cancel()
        session.watchdog = nil
        detachEngine(from: session)
    }

    /// Point the engine's input unit at a specific Core Audio device (macOS). Must happen before the
    /// input format is queried, because the format follows the device.
    private static func select(_ device: AudioInputDevice, on inputNode: AVAudioInputNode) throws {
        let unit = inputNode.auAudioUnit
        guard unit.deviceID != device.deviceID else { return }
        do {
            try unit.setDeviceID(device.deviceID)
        } catch {
            throw AudioCaptureError.engineStartFailed(
                "Could not select input device '\(device.name)': \(error.localizedDescription)"
            )
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch, \(Int(format.sampleRate)) Hz"
    }
}

// MARK: - Microphone permission abstraction

protocol MicrophonePermissionProviding: Sendable {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
