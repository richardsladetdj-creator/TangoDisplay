import AVFoundation
import AppKit
import Combine
import CoreAudioKit
import Foundation
import OSLog
import TangoDisplayCore
import TangoDisplayObjC

@MainActor
final class LocalPlayerSource: NSObject, ObservableObject, @preconcurrency MusicPlayerSource {

    // MARK: - MusicPlayerSource callbacks

    var onTrackUpdate: ((Track?, PlayerState) -> Void)?
    var onPlaylistUpdate: ((tracks: [Track], currentIndex: Int)?) -> Void = { _ in }
    var onNextTrackUpdate: ((Track?) -> Void)?
    var onWatchdogChanged: ((Bool) -> Void)?
    var supportsPlaylist: Bool { true }
    var isTransportControllable: Bool { true }

    // MARK: - Observable playback state (for PlayerControlsView)

    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentEntryID: UUID?
    /// True while the current track is paused in place (resume continues from `elapsed`).
    /// Distinct from `pause()`, which stops and rewinds the track to its start.
    @Published private(set) var isHeld = false
    @Published private(set) var isCurrentEntryMarkedAsPlayed: Bool = false
    @Published private(set) var isActivePlaying: Bool = false {
        didSet {
            guard isActivePlaying != oldValue else { return }
            // ponytail: idle-sleep assertion only, not a full power-source watcher — battery's
            // shorter idle-sleep timeout was suspending playback mid-track on unplug.
            if isActivePlaying {
                sleepAssertionToken = ProcessInfo.processInfo.beginActivity(
                    options: .idleSystemSleepDisabled,
                    reason: "TangoDisplay setlist playback"
                )
            } else if let token = sleepAssertionToken {
                ProcessInfo.processInfo.endActivity(token)
                sleepAssertionToken = nil
            }
        }
    }
    private var sleepAssertionToken: NSObjectProtocol?

    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = max(0, min(1, newValue)) }
    }

    private var _balance: Float = 0
    var balance: Float {
        get { _balance }
        set { _balance = max(-1, min(1, newValue)); applyBalance(_balance) }
    }

    // MARK: - Diagnostics

    @Published private(set) var replayGainStatus: String = ""
    @Published private(set) var hogModeConflict: Bool = false
    @Published private(set) var hogDeviceStolenAlert: Bool = false
    /// Set when the engine could not be restarted (device gone, or not yet back after wake).
    /// Playback is stopped rather than crashed; the UI offers Retry.
    @Published private(set) var engineStalled: Bool = false
    @Published private(set) var isChangingDevice: Bool = false

    // MARK: - Private — audio engine

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    // ShellacFilters restoration, ahead of the EQ so the record is repaired before it
    // is tone-shaped. nil when registration failed — the app then runs without them.
    private var declickUnit: AVAudioUnit?
    private var dehumUnit: AVAudioUnit?
    /// Which restoration nodes belong in the graph for the track being loaded. Read by
    /// connectAudioGraph, which is also called from paths that have no entry to hand.
    private var activeRestoration: (declick: Bool, dehum: Bool) = (false, false)
    private let replayGainMixer = AVAudioMixerNode()
    private let balanceMixer = AVAudioMixerNode()
    private var audioFile: AVAudioFile?
    private var seekOffset: Double = 0

    // MARK: - Level meter

    private(set) var levelMeter: AudioLevelMeter!

    // MARK: - Private — state

    let setlist: SetlistManager
    private let settings: AppSettings
    private let configStore: PluginConfigurationStore

    // Snapshot of chain state captured just before the first per-track config is applied.
    // Restored when the next unassigned track (with no default config) plays.
    private var preConfigSnapshot: PreConfigSnapshot? = nil

    // The configuration the chain currently holds. Reapplying the same one on the next
    // track would overwrite plugin edits made live during the set — with a default
    // configuration set, that fired on every single track load.
    private var appliedConfigurationID: UUID? = nil

    private struct PreConfigSnapshot {
        let chainEnabled: Bool
        let chainBypassed: Bool
        let slotStates: [PluginSlotState]
    }
    private var timeObserverTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var earlyMarkedEntryIDs: Set<UUID> = []
    private var scheduleGeneration: Int = 0
    private var pendingOutputRetryID: UUID?
    private var engineRecoveryGeneration: Int?
    private var scheduledPlaybackDuration: TimeInterval = 0
    private var playbackProgress: PlaybackProgress?

    /// Hog ownership is changed on `audioDeviceQueue` and released from `deinit`, so it lives
    /// outside main-actor state behind a lock.
    private final class HoggedDevice: @unchecked Sendable {
        private let lock = NSLock()
        private var uid: String?

        func set(_ newValue: String?) { lock.withLock { uid = newValue } }
        func take() -> String? { lock.withLock { defer { uid = nil }; return uid } }
    }
    private let hoggedDevice = HoggedDevice()
    private let audioDeviceQueue = DispatchQueue(label: "com.tangodisplay.audio-device", qos: .userInitiated)

    // MARK: - Private — Audio Unit plugin chain

    private let pluginManager = AudioUnitPluginManager()

    private final class SlotRuntime {
        var avUnit: AVAudioUnit?
        var status: AudioUnitPluginStatus = .noPluginSelected
        var presetManager: AudioUnitPresetManager?
        var availablePresets: [AudioUnitPreset] = []
        var activePresetID: UUID? = nil
        var pluginWindow: NSWindow?
        var pluginWindowVC: PluginWindowViewController?
        var paramObserverTree: AUParameterTree?
        var paramObserverToken: AUParameterObserverToken?
        var currentPresetObservation: NSKeyValueObservation?
        var loadGeneration: Int = 0
        var loadTask: Task<Void, Never>?
        var isApplyingPreset: Bool = false
    }

    private var slotRuntimes: [UUID: SlotRuntime] = [:]
    @Published private(set) var audioUnitPluginStatus: AudioUnitPluginStatus = .noPluginSelected
    @Published private(set) var slotStatuses: [UUID: AudioUnitPluginStatus] = [:]
    @Published private(set) var slotPresets: [UUID: [AudioUnitPreset]] = [:]
    @Published private(set) var slotActivePresetIDs: [UUID: UUID] = [:]

    // MARK: - Private — auto-gap

    private var currentPaddingFrames: AVAudioFrameCount = 0
    private var playableFrames: Range<AVAudioFramePosition>?
    private var preparedAutoGap: PreparedAutoGap?
    private var boundedAutoGap: PreparedAutoGap?
    private var analyzedGapPair: GapPair?
    private var autoGapAnalysisTask: Task<Void, Never>?
    private var autoGapCutoffTask: Task<Void, Never>?
    private var silencePending: Bool = false
    private var manualStopPending = false             // set by a user-initiated stop; consumed by the next loadEntry

    private struct GapPair: Equatable, Sendable {
        let currentID: UUID
        let currentURL: URL
        let currentStart: Double
        let currentEnd: Double
        let nextID: UUID
        let nextURL: URL
        let nextStart: Double?
        let nextEnd: Double?
        let measureMaximum: Bool
    }

    // MARK: - Private — loudness analysis

    private var inFlightAnalysisURLs = Set<URL>()
    private let loudnessCache = LoudnessAnalysisCache.shared

    // MARK: - Init

    init(setlist: SetlistManager, settings: AppSettings, configStore: PluginConfigurationStore, volume: Float = 1.0) {
        self.setlist = setlist
        self.settings = settings
        self.configStore = configStore
        super.init()
        setupAudioEngine()
        levelMeter = AudioLevelMeter(mixerNode: audioEngine.mainMixerNode)
        playerNode.volume = max(0, min(1, volume))
        applyOutputDevice(settings.builtInOutputDeviceUID)
        applyEQGains(settings.eqGains)
        _balance = max(-1, min(1, settings.builtInBalance))
        applyBalance(_balance)
    }

    // MARK: - Audio engine setup

    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(eq)
        audioEngine.attach(replayGainMixer)
        audioEngine.attach(balanceMixer)
        setupRestorationUnits()
        do {
            try connectAudioGraph(format: nil)
        } catch {
            os_log(.error, "TangoDisplay: initial audio graph failed: %{public}@", error.localizedDescription)
        }

        let frequencies: [Float]          = [60, 250, 1000, 4000, 12000]
        let filterTypes: [AVAudioUnitEQFilterType] = [.lowShelf, .parametric, .parametric, .parametric, .highShelf]
        for (i, band) in eq.bands.enumerated() {
            band.filterType = filterTypes[i]
            band.frequency  = frequencies[i]
            band.bandwidth  = 1.0
            band.gain       = 0.0
            band.bypass     = false
        }

        try? Self.startEngine(audioEngine)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )

        // Wake doesn't reliably produce a configuration-change notification, and the device may
        // not be back yet when it does. The handler is idempotent (re-asserts the device,
        // restarts with retries, re-seeks to `elapsed`), so a duplicate fire is harmless.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Shellac restoration

    /// Instantiates the two in-process units by description. They are registered with
    /// AudioComponent rather than published to AVAudioUnitComponentManager, so they
    /// never appear in the plugin picker and never occupy one of the four user slots.
    private func setupRestorationUnits() {
        guard TDRestorationRegister() else {
            os_log(.error, "TangoDisplay: shellac restoration unavailable; continuing without it")
            return
        }

        func make(_ subType: OSType) -> AVAudioUnit {
            var acd = AudioComponentDescription()
            acd.componentType = kAudioUnitType_Effect
            acd.componentSubType = subType
            acd.componentManufacturer = TDRestorationManufacturer
            return AVAudioUnitEffect(audioComponentDescription: acd)
        }

        let declick = make(TDDeclickSubType)
        let dehum = make(TDDehumSubType)
        audioEngine.attach(declick)
        audioEngine.attach(dehum)
        declickUnit = declick
        dehumUnit = dehum

        applyRestorationParams(settings.restoration)
        // Connected from the first graph build, so start them bypassed.
        applyRestorationEngagement((false, false))
    }

    /// Which restoration nodes this entry wants. A per-track override outranks both the
    /// master switch and the cortina rule — marking one transfer for repair is meant to
    /// work whether or not restoration is on for the set.
    private func restorationNodes(for entry: SetlistEntry?) -> (declick: Bool, dehum: Bool) {
        guard let entry else { return (false, false) }
        let r = settings.restoration

        let isCortina = r.skipOnCortinas && settings.makeDetector().isCortina(genre: entry.track.genre)
        let on = entry.restorationApplied(globalDefault: r.appliesByDefault(isCortina: isCortina))
        return (declick: on && r.declickEnabled && declickUnit != nil,
                dehum:   on && r.dehumEnabled   && dehumUnit   != nil)
    }

    /// Parameter moves are written straight through; the cores retune in place, so this
    /// never needs a graph rewire. Only engagement does.
    private func applyRestorationParams(_ r: RestorationSettings) {
        func write(_ unit: AVAudioUnit?, _ values: [Float]) {
            guard let tree = unit?.auAudioUnit.parameterTree else { return }
            for (address, value) in values.enumerated() {
                tree.parameter(withAddress: AUParameterAddress(address))?.value = value
            }
        }
        write(declickUnit, r.declickValues)
        write(dehumUnit, r.dehumValues)
    }

    /// Engagement is bypass, not graph topology. Both units stay connected, so switching
    /// restoration on or off mid-track is one atomic store rather than an engine restart —
    /// which is what used to drop a chunk of audio and jump the position by up to the 0.5 s
    /// poll interval. A bypassed unit runs its DSP with a wet mix of zero: output is the dry
    /// signal bit for bit, declick's pipeline stays primed and dehum keeps tracking its line,
    /// so switching back is instant and sample-aligned.
    private func applyRestorationEngagement(_ wanted: (declick: Bool, dehum: Bool),
                                            scoutIfNewlyOn: Bool = true) {
        let dehumNewlyOn = scoutIfNewlyOn && wanted.dehum && !activeRestoration.dehum
        activeRestoration = wanted
        declickUnit?.auAudioUnit.shouldBypassEffect = !wanted.declick
        dehumUnit?.auAudioUnit.shouldBypassEffect   = !wanted.dehum

        // Engaged part-way through a record, dehum has no scout behind it and would spend
        // 9-43 s acquiring the line with the hum still audible. loadEntry does its own
        // scouting; a later one supersedes it.
        if dehumNewlyOn,
           let entry = currentEntryID.flatMap({ id in setlist.entries.first { $0.id == id } }) {
            TDRestorationScout(dehumUnit?.auAudioUnit, entry.fileURL)
        }
    }

    /// Each record carries its own clicks and its own hum, so nothing carries over.
    /// Scouting reads the opening of the file off-thread and pre-seeds dehum's detector,
    /// which otherwise needs 9-43 s of playback before it engages.
    private func startRestorationForTrack(_ entry: SetlistEntry) {
        TDRestorationForgetTrack(declickUnit?.auAudioUnit)
        TDRestorationForgetTrack(dehumUnit?.auAudioUnit)
        if activeRestoration.dehum {
            TDRestorationScout(dehumUnit?.auAudioUnit, entry.fileURL)
        }
    }

    @objc nonisolated private func handleEngineConfigChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isChangingDevice, self.engineRecoveryGeneration == nil else { return }
            // Invalidate any pending dataPlayedBack callbacks so the system-forced engine stop
            // (e.g. headphone removal on System Default) doesn't spuriously fire handleTrackEnd → skipNext().
            self.scheduleGeneration += 1
            let generation = self.scheduleGeneration
            // Graph rewire must happen with engine stopped; engine is already stopped when this fires.
            if let file = self.audioFile {
                do {
                    try self.connectAudioGraph(format: file.processingFormat)
                } catch {
                    if self.isActivePlaying { self.recoverPlaybackFailure(error) }
                    return
                }
            }

            // Capture all state before leaving the main thread.
            guard let audioUnit = self.audioEngine.outputNode.audioUnit else {
                if self.isActivePlaying { self.interruptForUnavailableOutput() }
                self.engineStalled = true
                return
            }
            self.engineRecoveryGeneration = generation
            let uid = self.settings.builtInOutputDeviceUID
            let hogEnabled = self.settings.builtInHogMode
            let wasPlaying = self.isActivePlaying
            let savedElapsed = self.elapsed
            let engine = self.audioEngine
            let player = self.playerNode

            // Dispatch blocking CoreAudio work off the main thread to avoid a UI spinner.
            self.audioDeviceQueue.async { [weak self] in
                guard let self else { return }

                // Re-assert the user's chosen output device before restarting.
                Self.setOutputDeviceProperty(audioUnit: audioUnit, uid: uid)

                // Detect hog-mode theft by another process. Checked with hog mode on too —
                // sleep drops our claim, so another app can take the device while we're away.
                let deviceStolenByOther: Bool
                if !uid.isEmpty {
                    let owner = AudioDeviceManager.hogOwner(forUID: uid)
                    deviceStolenByOther = owner != -1 && owner != getpid()
                } else {
                    deviceStolenByOther = false
                }

                if deviceStolenByOther && wasPlaying {
                    player.stop()
                }

                // After wake the device can take seconds to come back, so one attempt isn't
                // enough. Blocking sleeps are fine here — audioDeviceQueue is the dedicated
                // serial queue for blocking CoreAudio work.
                var started = false
                for attempt in 0..<10 {
                    if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                    do {
                        try Self.startEngine(engine)
                        started = true
                        break
                    } catch {
                        os_log(.error, "TangoDisplay: engine restart attempt %d failed: %{public}@",
                               attempt, error.localizedDescription)
                    }
                }

                // Sleep releases hog mode; without this the device silently loses exclusivity
                // for the rest of the session.
                if started && !deviceStolenByOther {
                    self.reacquireHogIfNeeded(uid: uid, hogEnabled: hogEnabled)
                }

                DispatchQueue.main.async {
                    self.engineRecoveryGeneration = nil
                    guard self.scheduleGeneration == generation else { return }
                    if deviceStolenByOther {
                        self.hogModeConflict = true
                        if wasPlaying {
                            self.isActivePlaying = false
                            if let id = self.currentEntryID, !self.currentEntryIsPlayed() {
                                self.setlist.markPaused(id: id)
                            }
                            self.reportCurrentState()
                            self.hogDeviceStolenAlert = true
                            // Pulse back to false so future interruptions can re-trigger the alert.
                            DispatchQueue.main.async { self.hogDeviceStolenAlert = false }
                        }
                    } else if !started {
                        if wasPlaying { self.interruptForUnavailableOutput() }
                        self.engineStalled = true
                    } else {
                        self.engineStalled = false
                        self.levelMeter.reinstallTap()
                        self.applyBalance(self._balance)
                        if let retryID = self.pendingOutputRetryID {
                            self.playForward(from: self.setlist.entries.first { $0.id == retryID }, bypassAutoGap: true)
                        } else if self.audioFile != nil {
                            self.seekTo(savedElapsed, resume: wasPlaying)
                        }
                    }
                }
            }
        }
    }

    /// Acquires hog mode on `uid` if the user wants it. Must be called from `audioDeviceQueue`
    /// (CoreAudio property set can block); all @Published writes dispatch back to main.
    nonisolated private func reacquireHogIfNeeded(uid: String, hogEnabled: Bool) {
        guard hogEnabled && !uid.isEmpty else { return }
        if AudioDeviceManager.acquireHogMode(forUID: uid) {
            hoggedDevice.set(uid)
            DispatchQueue.main.async { self.hogModeConflict = false }
        } else {
            DispatchQueue.main.async { self.hogModeConflict = true }
            os_log(.error, "TangoDisplay: failed to acquire hog mode on %{public}@", uid)
        }
    }

    private func applyOutputDevice(_ uid: String) {
        // Fast pre-check on the calling thread — if another process owns the hog, leave the
        // engine on its current device so play continues to work without hanging.
        if !uid.isEmpty {
            let owner = AudioDeviceManager.hogOwner(forUID: uid)
            if owner != -1 && owner != getpid() {
                hogModeConflict = true
                os_log(.error, "TangoDisplay: device %{public}@ is hogged by pid %d", uid, owner)
                return
            }
        }
        hogModeConflict = false

        // Capture values on the calling thread (main) before dispatching blocking work.
        guard let audioUnit = audioEngine.outputNode.audioUnit else { return }
        let wasPlaying = isActivePlaying
        let savedElapsed = elapsed
        let hogEnabled = settings.builtInHogMode
        // Invalidate any pending dataPlayedBack callbacks before stopping the player node,
        // so the stop doesn't spuriously fire handleTrackEnd → skipNext().
        scheduleGeneration += 1
        let generation = scheduleGeneration

        isChangingDevice = true
        let engine = audioEngine
        let player = playerNode
        // AudioUnit is a raw pointer; the engine keeps it alive while this queue uses it.
        nonisolated(unsafe) let outputUnit = audioUnit

        audioDeviceQueue.async { [weak self] in
            guard let self else { return }

            // Release hog on the previous device.
            if let prev = self.hoggedDevice.take() {
                AudioDeviceManager.releaseHogMode(forUID: prev)
            }

            // CoreAudio stop/start can block — must be off the main thread.
            if engine.isRunning {
                player.stop()
                engine.stop()
            }

            Self.setOutputDeviceProperty(audioUnit: outputUnit, uid: uid)

            do {
                try Self.startEngine(engine)

                self.reacquireHogIfNeeded(uid: uid, hogEnabled: hogEnabled)

                // AVAudioEngine player ops and tap reinstall must be on main.
                DispatchQueue.main.async {
                    self.isChangingDevice = false
                    guard self.scheduleGeneration == generation else { return }
                    self.engineStalled = false
                    self.levelMeter.reinstallTap()
                    if let retryID = self.pendingOutputRetryID {
                        self.playForward(from: self.setlist.entries.first { $0.id == retryID }, bypassAutoGap: true)
                    } else if self.audioFile != nil {
                        self.seekTo(savedElapsed, resume: wasPlaying)
                    }
                }
            } catch {
                os_log(.error, "TangoDisplay: applyOutputDevice engine restart failed: %{public}@",
                       error.localizedDescription)
                DispatchQueue.main.async {
                    self.isChangingDevice = false
                    guard self.scheduleGeneration == generation else { return }
                    if wasPlaying { self.interruptForUnavailableOutput() }
                    self.engineStalled = true
                }
            }
        }
    }

    nonisolated private func applyHogMode(enabled: Bool, deviceUID: String) {
        // Must be called from audioDeviceQueue. All @Published writes dispatch back to main.
        if let prev = hoggedDevice.take() {
            AudioDeviceManager.releaseHogMode(forUID: prev)
        }
        guard enabled, !deviceUID.isEmpty else {
            let conflict: Bool
            if !deviceUID.isEmpty {
                let owner = AudioDeviceManager.hogOwner(forUID: deviceUID)
                conflict = owner != -1 && owner != getpid()
            } else {
                conflict = false
            }
            DispatchQueue.main.async { self.hogModeConflict = conflict }
            return
        }
        if AudioDeviceManager.acquireHogMode(forUID: deviceUID) {
            hoggedDevice.set(deviceUID)
            DispatchQueue.main.async { self.hogModeConflict = false }
        } else {
            DispatchQueue.main.async { self.hogModeConflict = true }
            os_log(.error, "TangoDisplay: failed to acquire hog mode on device %{public}@", deviceUID)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let uid = hoggedDevice.take()
        audioDeviceQueue.async {
            if let uid { AudioDeviceManager.releaseHogMode(forUID: uid) }
        }
    }

    nonisolated private static func setOutputDeviceProperty(audioUnit: AudioUnit, uid: String) {
        if uid.isEmpty {
            // Restore default device by reading system default
            var defaultID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &defaultID, size)
        } else if var deviceID = AudioDeviceManager.audioDeviceID(forUID: uid) {
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
    }

    private func applyEQGains(_ gains: [Float]) {
        for (i, band) in eq.bands.enumerated() where i < gains.count {
            band.gain = gains[i]
        }
    }

    private func applyBalance(_ pan: Float) {
        balanceMixer.pan = pan
    }

    private func applyReplayGain(for entry: SetlistEntry) {
        let rgSettings = ReplayGainSettings(
            mode: settings.replayGainMode,
            preampDb: Double(settings.replayGainPreampDb),
            preventClipping: settings.replayGainPreventClipping,
            targetLoudnessLufs: Double(settings.replayGainTargetLufs)
        )
        let info = entry.track.replayGainInfo
        let cacheKey = loudnessCacheKey(for: entry)
        let rawAnalysis = cacheKey.flatMap { loudnessCache.result(for: $0) }

        // Recalculate gain from cached integrated loudness if target has changed since analysis
        let analysis: LoudnessAnalysisResult? = rawAnalysis.map { cached in
            guard cached.targetLoudnessLufs != rgSettings.targetLoudnessLufs else { return cached }
            let newGainDb = rgSettings.targetLoudnessLufs - cached.integratedLoudnessLufs
            return LoudnessAnalysisResult(
                filePath: cached.filePath, fileSize: cached.fileSize,
                modifiedDate: cached.modifiedDate, duration: cached.duration,
                integratedLoudnessLufs: cached.integratedLoudnessLufs,
                calculatedReplayGainDb: newGainDb,
                targetLoudnessLufs: rgSettings.targetLoudnessLufs,
                samplePeak: cached.samplePeak, truePeak: cached.truePeak,
                analysedAt: cached.analysedAt
            )
        }

        let result = calculateReplayGain(info: info, analysis: analysis, settings: rgSettings)
        var finalGain = result.linearGain
        let cortinaCutDb = settings.cortinaVolumeReductionDb
        if cortinaCutDb < 0 {
            let detector = settings.makeDetector()
            if detector.isCortina(genre: entry.track.genre) {
                finalGain *= Float(pow(10.0, cortinaCutDb / 20.0))
            }
        }
        replayGainMixer.outputVolume = finalGain

        let analysisInFlight = inFlightAnalysisURLs.contains(entry.fileURL)
        replayGainStatus = replayGainStatusString(result: result, settings: rgSettings,
                                                   analysisInFlight: analysisInFlight)

        if settings.replayGainMode == .auto,
           info?.trackGainDb == nil,
           analysis == nil {
            queueLoudnessAnalysis(for: entry, isCurrentTrack: true)
        }
    }

    private func replayGainStatusString(result: ReplayGainCalculationResult,
                                         settings: ReplayGainSettings,
                                         analysisInFlight: Bool) -> String {
        guard settings.mode != .off else { return "" }
        switch result.source {
        case .none:
            if analysisInFlight { return "ReplayGain: Analysing…" }
            return settings.mode == .album ? "ReplayGain: No album metadata" : "ReplayGain: No metadata"
        case .metadataTrack:
            let suffix = result.clippingProtectionApplied ? " (clipping limited)" : ""
            return String(format: "ReplayGain: Track %+.1f dB\(suffix)", result.gainDb ?? 0)
        case .metadataAlbum:
            let suffix = result.clippingProtectionApplied ? " (clipping limited)" : ""
            return String(format: "ReplayGain: Album %+.1f dB\(suffix)", result.gainDb ?? 0)
        case .analysed:
            let lufsStr = result.integratedLoudnessLufs.map { String(format: " · %.1f LUFS", $0) } ?? ""
            let suffix = result.clippingProtectionApplied ? " (clipping limited)" : ""
            return String(format: "ReplayGain: Auto %+.1f dB\(lufsStr)\(suffix)", result.gainDb ?? 0)
        }
    }

    nonisolated private static func analysisStatusForError(_ error: Error) -> String {
        if error is CancellationError { return "ReplayGain: Cancelled" }
        switch error as? LoudnessAnalysisError {
        case .cannotOpenFile:    return "ReplayGain: Cannot read file"
        case .unsupportedFormat: return "ReplayGain: Unsupported format"
        case .insufficientData:  return "ReplayGain: Insufficient audio"
        case .none:              return "ReplayGain: Analysis failed"
        }
    }

    private func queueLoudnessAnalysis(for entry: SetlistEntry, isCurrentTrack: Bool) {
        let url = entry.fileURL
        guard !inFlightAnalysisURLs.contains(url) else { return }
        inFlightAnalysisURLs.insert(url)
        if isCurrentTrack { replayGainStatus = "ReplayGain: Analysing…" }

        let entryID = entry.id
        let targetLufs = Double(settings.replayGainTargetLufs)
        let cache = loudnessCache

        Task.detached(priority: .background) { [weak self] in
            let analysisResult: LoudnessAnalysisResult?
            let errorStatus: String?
            do {
                analysisResult = try await LoudnessAnalyzer.shared.analyse(
                    url: url, targetLoudnessLufs: targetLufs)
                errorStatus = nil
            } catch {
                analysisResult = nil
                errorStatus = LocalPlayerSource.analysisStatusForError(error)
            }

            if let result = analysisResult { cache.store(result) }

            let succeeded = analysisResult != nil
            let failStatus = errorStatus
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlightAnalysisURLs.remove(url)               // always runs
                guard self.currentEntryID == entryID else { return }
                if let currentEntry = self.setlist.entries.first(where: { $0.id == entryID }) {
                    self.applyReplayGain(for: currentEntry)         // re-reads cache or falls through
                }
                if !succeeded, let status = failStatus {
                    self.replayGainStatus = status
                }
            }
        }
    }

    private func preAnalyseIfNeeded(_ entry: SetlistEntry) {
        guard settings.replayGainMode == .auto,
              entry.track.replayGainInfo?.trackGainDb == nil else { return }
        if let key = loudnessCacheKey(for: entry),
           loudnessCache.result(for: key) != nil { return }
        queueLoudnessAnalysis(for: entry, isCurrentTrack: false)
    }

    private func loudnessCacheKey(for entry: SetlistEntry) -> LoudnessAnalysisCacheKey? {
        let path = entry.fileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int64,
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        return LoudnessAnalysisCacheKey(filePath: path, fileSize: fileSize, modifiedDate: modDate)
    }

    private func reapplyReplayGainIfLoaded() {
        guard let id = currentEntryID,
              let entry = setlist.entries.first(where: { $0.id == id }) else {
            replayGainStatus = ""
            return
        }
        applyReplayGain(for: entry)
    }

    // MARK: - MusicPlayerSource lifecycle

    func start() {
        setupObservers()
        reportCurrentState()
        reportPlaylist()
        initializePluginStatus()
    }

    func stop() {
        // Deactivating the source isn't a DJ stop, so leave manualStopPending alone.
        finishPlaybackAttempt()
        teardownObservers()
        for runtime in slotRuntimes.values {
            runtime.loadTask?.cancel()
            runtime.loadTask = nil
            runtime.pluginWindow?.close()
            runtime.pluginWindow = nil
            runtime.pluginWindowVC = nil
        }
        replayGainMixer.outputVolume = 1.0
        inFlightAnalysisURLs.removeAll()
        audioEngine.stop()
        levelMeter.reset()
    }

    func pollNow() {
        reportCurrentState()
        reportPlaylist()
    }

    func triggerPlaylistFetch() {
        reportPlaylist()
    }

    func fetchArtwork(for track: Track) async -> NSImage? {
        guard let url = URL(string: track.persistentID), url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first,
              let data = try? await item.load(.dataValue) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Transport controls

    func play() {
        if isHeld {
            resumeHeld()
            return
        }
        // Non-blocking: a stale result only means a missing file fails and gets skipped.
        setlist.refreshMediaAvailability()
        if let id = currentEntryID, earlyMarkedEntryIDs.contains(id) || currentEntryIsPlayed() {
            skipNext()
            return
        }
        let first = setlist.firstPlayable
        // Keep the usual topmost playable row after a reorder.
        if let id = currentEntryID, audioFile != nil, first?.id == id {
            manualStopPending = false
            seekTo(0, resume: true)
            return
        }
        let preferredID = pendingOutputRetryID ?? (audioFile == nil ? currentEntryID : nil)
        let entry = preferredID.flatMap { id in setlist.entries.first { $0.id == id && setlist.isPlayable($0) } } ?? first
        if let id = currentEntryID, id != entry?.id, audioFile != nil {
            setlist.markQueued(id: id)
        }
        playForward(from: entry)
    }

    /// Pauses at the current position without rewinding or advancing. The track keeps
    /// its row and played status; `resumeHeld()` (or `play()`) continues from here.
    func holdPause() {
        guard isActivePlaying, audioFile != nil, let id = currentEntryID else { return }
        scheduleGeneration += 1
        cancelAutoGapCutoff()
        playerNode.stop()
        isActivePlaying = false
        isHeld = true
        if !earlyMarkedEntryIDs.contains(id), !currentEntryIsPlayed() {
            setlist.markPaused(id: id)
        }
        // Reschedule from the held position (node stopped, so this doesn't start playback).
        seekTo(elapsed)
        reportCurrentState()
    }

    func resumeHeld() {
        guard isHeld else { return }
        isHeld = false
        manualStopPending = false
        seekTo(elapsed, resume: true)
    }

    func pause() {
        isHeld = false
        pendingOutputRetryID = nil
        manualStopPending = true
        scheduleGeneration += 1
        playerNode.stop()
        isActivePlaying = false
        if let id = currentEntryID, !earlyMarkedEntryIDs.contains(id), !currentEntryIsPlayed() {
            setlist.markPaused(id: id)
            seekTo(0)
            elapsed = 0
            reportCurrentState()
        } else if let id = currentEntryID, let nextEntry = setlist.firstUnplayed(after: id) {
            audioFile = nil
            seekOffset = 0
            currentEntryID = nextEntry.id
            elapsed = 0
            duration = nextEntry.duration ?? 0
            reportCurrentState()
            reportPlaylist()
            onNextTrackUpdate?(setlist.entry(after: nextEntry.id)?.track)
        } else {
            audioFile = nil
            seekOffset = 0
            currentEntryID = nil
            elapsed = 0
            duration = 0
            reportCurrentState()
            reportPlaylist()
            onNextTrackUpdate?(nil)
        }
    }

    func stopTrack() {
        manualStopPending = true
        finishPlaybackAttempt()
    }

    private func finishPlaybackAttempt() {
        isHeld = false
        pendingOutputRetryID = nil
        if let id = currentEntryID, let state = setlist.entries.first(where: { $0.id == id })?.state,
           state == .playing || state == .paused {
            setlist.markQueued(id: id)
        }
        if let id = currentEntryID { setlist.setAutoGapApplied(id: id, applied: false) }
        scheduleGeneration += 1
        currentEntryID = nil
        isCurrentEntryMarkedAsPlayed = false
        isActivePlaying = false
        replayGainStatus = ""
        playerNode.stop()
        audioFile = nil
        elapsed = 0
        duration = 0
        seekOffset = 0
        currentPaddingFrames = 0
        silencePending = false
        playbackProgress = nil
        playableFrames = nil
        resetAutoGapAnalysis()
        reportCurrentState()
        reportPlaylist()
        onNextTrackUpdate?(nil)
    }

    func skipNext() { advance(bypassAutoGap: false) }

    func skipNextImmediate() { advance(bypassAutoGap: true) }

    private func advance(bypassAutoGap: Bool, naturalEnd: Bool = false, outgoingTrim: Double = 0) {
        guard let id = currentEntryID else { play(); return }
        let finished = setlist.entries.first { $0.id == id }
        let shouldStop = id == setlist.stopAfterEntryID
            || (finished?.isPerformance == true && settings.stopAfterEachPerformanceTrack)
        if !shouldStop, let finished, finished.repeatTrack {
            playForward(from: finished, bypassAutoGap: true)
            return
        }
        let next = shouldStop ? nil : setlist.firstUnplayed(after: id)
        let adjustment = naturalEnd && !bypassAutoGap
            ? next.flatMap { boundedGap(to: $0, outgoingTrim: outgoingTrim) } : nil
        setlist.markPlayed(id: id)
        if id == setlist.stopAfterEntryID { setlist.stopAfterEntryID = nil }
        playForward(from: next, bypassAutoGap: bypassAutoGap,
                    gapAdjustment: adjustment.flatMap { $0.trailingTrim <= 0.015 ? $0 : nil })
    }

    func skipPrevious() {
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        guard let id = currentEntryID else { return }
        if let previous = setlist.entry(before: id) {
            playForward(from: previous, shouldPlay: isActivePlaying)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) { seekTo(seconds) }

    func jumpTo(_ entry: SetlistEntry) {
        playForward(from: setlist.entries.first { $0.id == entry.id })
    }

    func retryOutputDevice() {
        applyOutputDevice(settings.builtInOutputDeviceUID)
    }

    private func playForward(from first: SetlistEntry?, bypassAutoGap: Bool = false,
                             shouldPlay: Bool = true, gapAdjustment: PreparedAutoGap.Adjustment? = nil) {
        runPlayback(.start(first, bypassAutoGap: bypassAutoGap), shouldPlay: shouldPlay,
                    gapAdjustment: gapAdjustment)
    }

    private func runPlayback(_ request: PlaybackRecovery.Request, shouldPlay: Bool = true,
                             gapAdjustment: PreparedAutoGap.Adjustment? = nil) {
        pendingOutputRetryID = nil
        let outcome = PlaybackRecovery.run(request, nextAfter: setlist.firstUnplayed(after:),
                                           attempt: { entry, bypassAutoGap in
            isActivePlaying = false
            try loadEntry(entry, bypassAutoGap: bypassAutoGap, gapAdjustment: bypassAutoGap ? nil : gapAdjustment)
            guard currentEntryID == entry.id, audioFile != nil else {
                throw PlaybackFailure.track("The audio track could not be prepared.")
            }
            if shouldPlay { try startPlayerNode() }
        }, didFail: markTrackFailed(_:error:))

        switch outcome {
        case .started(let entry):
            setlist.setCurrentEntry(id: entry.id, paused: !shouldPlay)
            refreshAutoGapAnalysis()
            reportCurrentState()
            reportPlaylist()
            onNextTrackUpdate?(setlist.firstUnplayed(after: entry.id)?.track)
        case .waitingForOutput(let entry):
            finishPlaybackAttempt()
            pendingOutputRetryID = shouldPlay ? entry.id : nil
            engineStalled = true
        case .exhausted:
            finishPlaybackAttempt()
        }
    }

    private func markTrackFailed(_ id: UUID, error: Error) {
        os_log(.error, "TangoDisplay: skipping track: %{public}@", error.localizedDescription)
        setlist.markPlaybackFailure(id: id, reason: error.localizedDescription)
        if id == setlist.stopAfterEntryID { setlist.stopAfterEntryID = nil }
    }

    private func recoverPlaybackFailure(_ error: Error) {
        guard let id = currentEntryID else { finishPlaybackAttempt(); return }
        runPlayback(.recover(after: id, error: error))
    }

    private func interruptForUnavailableOutput() {
        guard let id = currentEntryID else { finishPlaybackAttempt(); return }
        markTrackFailed(id, error: PlaybackFailure.track("The audio output was interrupted. This track was skipped."))
        let nextID = setlist.firstUnplayed(after: id)?.id
        finishPlaybackAttempt()
        pendingOutputRetryID = nextID
    }

    nonisolated private static func startEngine(_ engine: AVAudioEngine) throws {
        var reason: NSString?
        guard TDTryAudioEngineStart(engine, &reason) else {
            throw PlaybackFailure.track((reason as String?) ?? "Couldn’t start the audio engine.")
        }
    }

    private func startPlayerNode() throws {
        if !audioEngine.isRunning {
            do {
                try Self.startEngine(audioEngine)
            } catch {
                os_log(.error, "TangoDisplay: audio engine start failed: %{public}@", error.localizedDescription)
                throw PlaybackFailure.outputUnavailable
            }
        }
        var reason: NSString?
        guard TDTryAudioPlayerPlay(playerNode, &reason) else {
            throw PlaybackFailure.track((reason as String?) ?? "Couldn’t start the audio track.")
        }
        playbackProgress = PlaybackProgress(startedAt: ProcessInfo.processInfo.systemUptime,
                                            scheduledDuration: scheduledPlaybackDuration)
        engineStalled = false
        isActivePlaying = true
    }

    private func schedule(_ file: AVAudioFile, start: AVAudioFramePosition = 0,
                          count: AVAudioFrameCount = 0, generation: Int) throws {
        var reason: NSString?
        guard TDTryAudioPlayerSchedule(playerNode, file, start, count, { [weak self] in
            DispatchQueue.main.async { self?.handleTrackEnd(generation: generation) }
        }, &reason) else {
            throw PlaybackFailure.track((reason as String?) ?? "Couldn’t schedule the audio track.")
        }
        let frames = count == 0 ? file.length : AVAudioFramePosition(count)
        scheduledPlaybackDuration = (Double(frames) + Double(currentPaddingFrames)) / file.fileFormat.sampleRate
    }

    // MARK: - Private: seek implementation

    private func seekTo(_ seconds: Double, resume: Bool = false) {
        guard let file = audioFile, let range = playableFrames, seconds.isFinite else { return }
        let sampleRate = file.fileFormat.sampleRate
        let start = max(Double(range.lowerBound), seconds * sampleRate)
        guard start < Double(range.upperBound) else {
            if resume { skipNext() }
            return
        }
        let startFrame = AVAudioFramePosition(start)
        let frameCount = AVAudioFrameCount(clamping: range.upperBound - startFrame)
        let wasPlaying = resume || playerNode.isPlaying
        scheduleGeneration += 1
        cancelAutoGapCutoff()
        playerNode.stop()
        seekOffset = Double(startFrame) / sampleRate
        elapsed = seekOffset
        currentPaddingFrames = 0
        silencePending = false
        do {
            try schedule(file, start: startFrame, count: frameCount, generation: scheduleGeneration)
            if wasPlaying {
                try startPlayerNode()
                if let id = currentEntryID,
                   setlist.entries.first(where: { $0.id == id })?.state == .paused {
                    setlist.setCurrentEntry(id: id)
                }
                reportCurrentState()
            }
        } catch PlaybackFailure.outputUnavailable {
            interruptForUnavailableOutput()
            engineStalled = true
        } catch {
            if wasPlaying {
                recoverPlaybackFailure(error)
            } else {
                finishPlaybackAttempt()
            }
        }
    }

    // MARK: - Private: entry loading

    private func loadEntry(_ entry: SetlistEntry, bypassAutoGap: Bool = false,
                           gapAdjustment: PreparedAutoGap.Adjustment? = nil) throws {
        earlyMarkedEntryIDs.remove(entry.id)
        isCurrentEntryMarkedAsPlayed = false
        isHeld = false
        scheduleGeneration += 1
        cancelAutoGapCutoff()
        let gen = scheduleGeneration
        playerNode.stop()
        var reason: NSString?
        guard let file = TDTryOpenAudioFile(entry.fileURL, &reason) else {
            throw PlaybackFailure.track((reason as String?) ?? "Couldn’t read the audio file.")
        }
        guard file.length > 0, file.fileFormat.sampleRate.isFinite, file.fileFormat.sampleRate > 0,
              file.processingFormat.channelCount > 0 else {
            throw PlaybackFailure.track("This track contains no playable audio.")
        }
        audioFile = file
        seekOffset = 0
        elapsed = 0
        duration = Double(file.length) / file.fileFormat.sampleRate
        // scheduleFile requires the file format to exactly match the output bus format.
        // Stop the engine before reconnecting so the graph is in a clean state; a mono
        // AIFF scheduled against the stereo-defaulted startup connection produces silence.
        audioEngine.stop()
        // startRestorationForTrack owns the scout for a track load, so don't fire a
        // second one from here.
        applyRestorationEngagement(restorationNodes(for: entry), scoutIfNewlyOn: false)
        try connectAudioGraph(format: file.processingFormat)
        do {
            try Self.startEngine(audioEngine)
        } catch {
            os_log(.error, "TangoDisplay: engine start for track failed: %{public}@", error.localizedDescription)
            throw PlaybackFailure.outputUnavailable
        }
        levelMeter.reinstallTap()
        startRestorationForTrack(entry)
        applyReplayGain(for: entry)

        // Pre-warm loudness analysis for the next track so it's cached before it starts.
        if let nextEntry = setlist.entry(after: entry.id) {
            preAnalyseIfNeeded(nextEntry)
        }

        // Auto-gap: schedule silence before the file if needed.
        // preparedAutoGap is pre-populated by the background analysis from the previous track's loadEntry.
        currentPaddingFrames = 0
        silencePending = false
        let isFirstTrack = setlist.entries.first?.id == entry.id
            && !setlist.entries.contains(where: { $0.state == .played })
        var autoGapApplied = false
        let autoGapIgnored = entry.autoGapIgnored(isFirstTrack: isFirstTrack,
                                                  ignoreFirstTrack: settings.autoGapIgnoreFirstTrack)
        // A manual stop already created the gap; don't add a second one on the next start.
        let skipForManualStop = settings.autoGapSkipAfterManualStop && manualStopPending
        if !bypassAutoGap && !skipForManualStop && !autoGapIgnored && settings.autoGapEnabled {
            // Use the analysis prepared for this exact (outgoing, incoming) pair.
            // currentEntryID still holds the outgoing track here (set to the new
            // entry below). A stale/mismatched pair → nil → conservative full target.
            let padding = gapAdjustment?.padding ?? preparedAutoGap?.injectedDuration(
                currentID: currentEntryID ?? entry.id,
                nextID: entry.id,
                target: settings.autoGapDuration
            ) ?? settings.autoGapDuration
            if padding > 0 {
                let frameCount = (padding * file.fileFormat.sampleRate).rounded(.down)
                if frameCount >= 1, let frames = AVAudioFrameCount(exactly: frameCount),
                   let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                    buffer.frameLength = frames
                    try scheduleGap(buffer, entryID: entry.id, generation: gen)
                    silencePending = true
                    currentPaddingFrames = frames
                    autoGapApplied = true
                }
            }
        }
        setlist.setAutoGapApplied(id: entry.id, applied: autoGapApplied)
        resetAutoGapAnalysis()
        manualStopPending = false

        let range = try trackFrames(file, entry: entry, leadingTrim: gapAdjustment?.leadingTrim ?? 0)
        playableFrames = range
        if range.lowerBound == 0 && range.upperBound == file.length {
            try schedule(file, generation: gen)
        } else {
            seekOffset = Double(range.lowerBound) / file.fileFormat.sampleRate
            elapsed = seekOffset
            try schedule(file, start: range.lowerBound, count: AVAudioFrameCount(clamping: range.count),
                         generation: gen)
        }

        currentEntryID = entry.id
        let resolvedConfigID = entry.pluginConfigurationID ?? configStore.defaultConfigurationID
        if let configID = resolvedConfigID, let config = configStore.configuration(id: configID) {
            if preConfigSnapshot == nil {
                preConfigSnapshot = PreConfigSnapshot(
                    chainEnabled: settings.audioUnitPluginEnabled,
                    chainBypassed: settings.audioUnitPluginBypassed,
                    slotStates: captureChainConfiguration()
                )
            }
            if !settings.audioUnitPluginEnabled { enableAudioUnitPlugin() }
            // Only reapply when the chain isn't already holding this configuration, so
            // live tweaks survive consecutive tracks that resolve to the same one.
            if appliedConfigurationID != configID {
                applyChainConfiguration(config)
                appliedConfigurationID = configID
            }
        } else if let snapshot = preConfigSnapshot {
            restorePreConfigSnapshot(snapshot)
            preConfigSnapshot = nil
            appliedConfigurationID = nil
        }
    }

    private func trackFrames(_ file: AVAudioFile, entry: SetlistEntry,
                             leadingTrim: Double) throws -> Range<AVAudioFramePosition> {
        let rate = file.fileFormat.sampleRate
        let start = max(0, entry.trimStartSeconds ?? 0)
        let end = min(duration, entry.trimEndSeconds ?? duration)
        guard start.isFinite, end.isFinite, start < end else {
            throw PlaybackFailure.track("This track has an invalid start or end time.")
        }
        let endFrame = end == duration
            ? file.length : AVAudioFramePosition(exactly: (end * rate).rounded(.down))
        guard let startFrame = AVAudioFramePosition(exactly: (start * rate).rounded(.down)),
              let endFrame, endFrame > startFrame else {
            throw PlaybackFailure.track("This track’s trim contains no playable audio.")
        }
        let removed = AVAudioFramePosition(exactly: (leadingTrim * rate).rounded(.down)) ?? 0
        let firstFrame = startFrame + min(removed, endFrame - startFrame - 1)
        return firstFrame..<endFrame
    }

    // MARK: - Automatic transition timing

    private func gapPair(to next: SetlistEntry) -> GapPair? {
        guard let id = currentEntryID, let file = audioFile, let range = playableFrames else { return nil }
        let rate = file.fileFormat.sampleRate
        return GapPair(currentID: id, currentURL: file.url,
                       currentStart: Double(range.lowerBound) / rate, currentEnd: Double(range.upperBound) / rate,
                       nextID: next.id, nextURL: next.fileURL, nextStart: next.trimStartSeconds,
                       nextEnd: next.trimEndSeconds, measureMaximum: settings.autoGapMaximum != nil)
    }

    private func refreshAutoGapAnalysis() {
        guard settings.autoGapEnabled, let id = currentEntryID, let file = audioFile,
              let next = setlist.firstUnplayed(after: id), let pair = gapPair(to: next) else {
            resetAutoGapAnalysis()
            return
        }
        guard pair != analyzedGapPair else { return }
        resetAutoGapAnalysis()
        analyzedGapPair = pair
        let duration = Double(file.length) / file.fileFormat.sampleRate
        autoGapAnalysisTask = Task { @MainActor [weak self] in
            let analyzer = AudioSilenceAnalyzer.shared
            let current = await analyzer.analyze(url: pair.currentURL)
            guard !Task.isCancelled else { return }
            let incoming = await analyzer.analyze(url: pair.nextURL)
            guard !Task.isCancelled, self?.analyzedGapPair == pair else { return }

            self?.preparedAutoGap = PreparedAutoGap(currentID: pair.currentID, nextID: pair.nextID,
                trailing: max(0, current.silenceAtEnd - max(0, duration - pair.currentEnd)),
                leading: max(0, incoming.silenceAtStart - (pair.nextStart ?? 0)))

            guard pair.measureMaximum,
                  let trailing = await analyzer.quietEdge(of: pair.currentURL,
                      from: pair.currentStart, to: pair.currentEnd, edge: .trailing),
                  !Task.isCancelled,
                  let leading = await analyzer.quietEdge(of: pair.nextURL,
                      from: pair.nextStart, to: pair.nextEnd, edge: .leading),
                  !Task.isCancelled, self?.analyzedGapPair == pair else { return }

            self?.boundedAutoGap = PreparedAutoGap(currentID: pair.currentID, nextID: pair.nextID,
                                                   trailing: trailing, leading: leading)
            self?.checkAutoGapCutoff()
        }
    }

    private func resetAutoGapAnalysis() {
        autoGapAnalysisTask?.cancel()
        autoGapAnalysisTask = nil
        cancelAutoGapCutoff()
        analyzedGapPair = nil
        preparedAutoGap = nil
        boundedAutoGap = nil
    }

    private func cancelAutoGapCutoff() {
        autoGapCutoffTask?.cancel()
        autoGapCutoffTask = nil
    }

    private func boundedGap(to next: SetlistEntry, outgoingTrim: Double = 0) -> PreparedAutoGap.Adjustment? {
        guard let maximum = settings.autoGapMaximum, let id = currentEntryID,
              !next.autoGapIgnored(isFirstTrack: false, ignoreFirstTrack: settings.autoGapIgnoreFirstTrack),
              let pair = gapPair(to: next), pair == analyzedGapPair else { return nil }
        return boundedAutoGap?.adjustment(currentID: id, nextID: next.id, minimum: settings.autoGapDuration,
                                          maximum: maximum, outgoingTrimApplied: outgoingTrim)
    }

    private func checkAutoGapCutoff() {
        guard autoGapCutoffTask == nil, isActivePlaying, !silencePending, !isChangingDevice,
              engineRecoveryGeneration == nil, audioEngine.isRunning, playerNode.isPlaying,
              let id = currentEntryID, id != setlist.stopAfterEntryID,
              let current = setlist.entries.first(where: { $0.id == id }), !current.repeatTrack,
              !(current.isPerformance && settings.stopAfterEachPerformanceTrack),
              let next = setlist.firstUnplayed(after: id),
              let adjustment = boundedGap(to: next), adjustment.trailingTrim > 0,
              let edges = boundedAutoGap, let pair = analyzedGapPair,
              let file = audioFile, let time = playerNode.lastRenderTime, time.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: time)
        else { return }

        let position = seekOffset + Double(max(0, playerTime.sampleTime - AVAudioFramePosition(currentPaddingFrames)))
            / file.fileFormat.sampleRate
        let quietStart = pair.currentEnd - edges.trailing
        let deadline = pair.currentEnd - adjustment.trailingTrim
        // Leave a small margin for main-thread scheduling and the audio render clock.
        let cutoff = max(quietStart, deadline - 0.035)
        if position >= cutoff {
            // After a missed deadline, leave the original schedule and minimum-gap behavior in place.
            guard position <= deadline + 0.015 else { return }
            advance(bypassAutoGap: false, naturalEnd: true, outgoingTrim: pair.currentEnd - position)
            return
        }

        let delay = cutoff - position
        guard delay <= 0.75 else { return }  // The progress timer will come back closer to the end.
        let generation = scheduleGeneration
        autoGapCutoffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.005, delay)))
            guard !Task.isCancelled, let self else { return }
            self.autoGapCutoffTask = nil
            guard self.scheduleGeneration == generation else { return }
            self.checkAutoGapCutoff()
        }
    }

    private func scheduleGap(_ buffer: AVAudioPCMBuffer, entryID: UUID, generation: Int) throws {
        var reason: NSString?
        guard TDTryAudioPlayerScheduleBuffer(playerNode, buffer, { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.silencePending = false
                self.setlist.setAutoGapApplied(id: entryID, applied: false)
            }
        }, &reason) else {
            throw PlaybackFailure.track((reason as String?) ?? "Couldn’t schedule the audio gap.")
        }
    }

    private func handleTrackEnd(generation: Int) {
        guard generation == scheduleGeneration, isActivePlaying,
              audioEngine.isRunning, engineRecoveryGeneration == nil else { return }
        if playbackProgress?.endedPrematurely(now: ProcessInfo.processInfo.systemUptime) == true {
            recoverPlaybackFailure(PlaybackFailure.track("The audio stream ended unexpectedly."))
        } else {
            advance(bypassAutoGap: false, naturalEnd: true)
        }
    }

    private func currentEntryIsPlayed() -> Bool {
        guard let id = currentEntryID else { return false }
        return setlist.entries.first(where: { $0.id == id })?.state == .played
    }

    // MARK: - Private: audio graph

    private func liveChainUnits() -> [(slot: AudioUnitChainSlot, unit: AVAudioUnit)] {
        guard settings.audioUnitPluginEnabled, !settings.audioUnitPluginBypassed else { return [] }
        return settings.audioUnitPluginChain.compactMap { slot in
            guard slot.isEnabled,
                  let runtime = slotRuntimes[slot.id],
                  let unit = runtime.avUnit else { return nil }
            return (slot, unit)
        }
    }

    // MARK: - Plugin chain configuration capture / apply

    func captureChainConfiguration() -> [PluginSlotState] {
        settings.audioUnitPluginChain.compactMap { slot in
            guard let runtime = slotRuntimes[slot.id],
                  let unit = runtime.avUnit,
                  let fullState = unit.auAudioUnit.fullState,
                  let encoded = try? AUStateCodec.encode(fullState)
            else { return nil }
            return PluginSlotState(
                slotID: slot.id,
                componentSubType: slot.selection.componentSubType,
                auState: encoded,
                isEnabled: slot.isEnabled
            )
        }
    }

    func applyChainConfiguration(_ config: PluginChainConfiguration) {
        for slotState in config.slotStates {
            guard let runtime = slotRuntimes[slotState.slotID],
                  let unit = runtime.avUnit else { continue }
            applySlotState(slotState, to: unit, runtime: runtime)
            setSlotEnabled(id: slotState.slotID, enabled: slotState.isEnabled)
        }
    }

    private func restorePreConfigSnapshot(_ snapshot: PreConfigSnapshot) {
        for slotState in snapshot.slotStates {
            guard let runtime = slotRuntimes[slotState.slotID],
                  let unit = runtime.avUnit else { continue }
            applySlotState(slotState, to: unit, runtime: runtime)
            setSlotEnabled(id: slotState.slotID, enabled: slotState.isEnabled)
        }
        if snapshot.chainBypassed != settings.audioUnitPluginBypassed {
            bypassAudioUnitPlugin(snapshot.chainBypassed)
        }
        if snapshot.chainEnabled != settings.audioUnitPluginEnabled {
            if snapshot.chainEnabled { enableAudioUnitPlugin() } else { disableAudioUnitPlugin() }
        }
    }

    private func applySlotState(_ slotState: PluginSlotState, to unit: AVAudioUnit, runtime: SlotRuntime) {
        guard let fullState = try? AUStateCodec.decode(slotState.auState) else { return }
        runtime.isApplyingPreset = true
        unit.auAudioUnit.fullState = fullState
        runtime.activePresetID = nil
        slotActivePresetIDs.removeValue(forKey: slotState.slotID)
        updateSlotPresetName(slotId: slotState.slotID, name: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak runtime] in
            runtime?.isApplyingPreset = false
        }
    }

    private func connectAudioGraph(format: AVAudioFormat?) throws {
        func connect(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
            var reason: NSString?
            guard TDTryAudioEngineConnect(audioEngine, source, destination, format, &reason) else {
                throw PlaybackFailure.track((reason as String?) ?? "Couldn’t connect the audio graph.")
            }
        }

        audioEngine.disconnectNodeOutput(playerNode)
        if let unit = declickUnit { audioEngine.disconnectNodeOutput(unit) }
        if let unit = dehumUnit { audioEngine.disconnectNodeOutput(unit) }
        audioEngine.disconnectNodeOutput(eq)
        audioEngine.disconnectNodeOutput(replayGainMixer)
        for runtime in slotRuntimes.values {
            if let unit = runtime.avUnit {
                audioEngine.disconnectNodeOutput(unit)
            }
        }
        audioEngine.disconnectNodeOutput(balanceMixer)

        // Shellac restoration first: repair the record before shaping it. Wired with the
        // file's own format, mono included — declick works on mono, unlike the Airwindows
        // declicker it derives from. Both nodes stay in the graph whether or not they are
        // engaged: engagement is expressed as bypass (see applyRestorationEngagement), which
        // costs an atomic store instead of the engine restart a rewire would need. The price
        // is declick's ~20 ms of latency and a little DSP on every track.
        var preEQ: AVAudioNode = playerNode
        if let unit = declickUnit {
            try connect(preEQ, to: unit, format: format)
            preEQ = unit
        }
        if let unit = dehumUnit {
            try connect(preEQ, to: unit, format: format)
            preEQ = unit
        }
        try connect(preEQ, to: eq, format: format)
        try connect(eq, to: replayGainMixer, format: format)

        // AU plugins often don't support mono. Upmix to stereo here so replayGainMixer
        // (AVAudioMixerNode) does the channel conversion before the plugin chain sees any data.
        let pluginFormat: AVAudioFormat? = {
            guard let fmt = format, fmt.channelCount < 2 else { return format }
            return AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 2)
        }()

        var prev: AVAudioNode = replayGainMixer
        var failedSlots: [(id: UUID, reason: String)] = []
        for (slot, unit) in liveChainUnits() {
            if let fmt = pluginFormat {
                do {
                    try unit.auAudioUnit.inputBusses[0].setFormat(fmt)
                } catch {
                    os_log(.error, "TangoDisplay: plugin '%{public}@' rejected format; disabling: %{public}@",
                           slot.selection.name, error.localizedDescription)
                    failedSlots.append((id: slot.id, reason: error.localizedDescription))
                    continue
                }
            }
            var connectReason: NSString?
            if TDTryAudioEngineConnect(audioEngine, prev, unit, pluginFormat, &connectReason) {
                prev = unit
            } else {
                let msg = (connectReason as String?) ?? "NSException during connect"
                os_log(.error, "TangoDisplay: plugin '%{public}@' connect threw exception; disabling: %{public}@",
                       slot.selection.name, msg)
                failedSlots.append((id: slot.id, reason: msg))
            }
        }
        for (id, reason) in failedSlots {
            markSlotFailed(id: id, reason: reason)
        }
        try connect(prev, to: balanceMixer, format: pluginFormat)
        try connect(balanceMixer, to: audioEngine.mainMixerNode, format: pluginFormat)
    }

    private func rewireGraphSafely() {
        let wasPlaying = isActivePlaying
        let savedElapsed = elapsed
        let format = audioFile?.processingFormat

        scheduleGeneration += 1
        playerNode.stop()
        audioEngine.stop()

        // If a plugin in the live chain breaks engine startup (e.g. format incompatibility),
        // drop slots from the end of the live chain one at a time and retry until it starts
        // — this preserves the working portion of the chain.
        while true {
            do {
                try connectAudioGraph(format: format)
                try Self.startEngine(audioEngine)
                break
            } catch {
                let live = liveChainUnits()
                guard let last = live.last else {
                    os_log(.error, "TangoDisplay: engine start failed with no live plugins: %{public}@",
                           error.localizedDescription)
                    if wasPlaying { recoverPlaybackFailure(error) }
                    else if audioFile != nil { finishPlaybackAttempt() }
                    recomputeChainStatus()
                    return
                }
                os_log(.error, "TangoDisplay: engine start failed; disabling slot %{public}@: %{public}@",
                       last.slot.selection.name, error.localizedDescription)
                markSlotFailed(id: last.slot.id, reason: error.localizedDescription)
                audioEngine.stop()
            }
        }

        levelMeter.reinstallTap()
        applyBalance(_balance)
        if audioFile != nil {
            seekTo(savedElapsed, resume: wasPlaying)
        }
        recomputeChainStatus()
    }

    private func markSlotFailed(id: UUID, reason: String) {
        guard let runtime = slotRuntimes[id] else { return }
        let name = settings.audioUnitPluginChain.first(where: { $0.id == id })?.selection.name ?? ""
        runtime.status = .failed(name, reason: reason)
        slotStatuses[id] = runtime.status
        if let unit = runtime.avUnit {
            audioEngine.disconnectNodeOutput(unit)
            audioEngine.detach(unit)
        }
        teardownSlotObservers(runtime)
        runtime.avUnit = nil
    }

    // MARK: - Audio Unit chain actions

    /// Append a plugin to the chain. No-op if the chain is already at the max.
    @discardableResult
    func addPluginSlot(_ selection: AudioUnitPluginSelection) -> UUID? {
        guard settings.audioUnitPluginChain.count < AudioUnitChainSlot.maxSlots else { return nil }
        let slot = AudioUnitChainSlot(selection: selection, isEnabled: true)
        settings.audioUnitPluginChain.append(slot)
        slotRuntimes[slot.id] = SlotRuntime()
        slotStatuses[slot.id] = .loading(selection.name)
        if settings.audioUnitPluginEnabled {
            startSlotLoad(slot)
        } else {
            slotStatuses[slot.id] = .disabled
        }
        recomputeChainStatus()
        return slot.id
    }

    /// Replace what's loaded in an existing slot. Preserves the slot's id and position.
    func replacePluginSlot(id: UUID, with selection: AudioUnitPluginSelection) {
        guard let index = settings.audioUnitPluginChain.firstIndex(where: { $0.id == id }) else { return }
        tearDownSlot(id: id, detachAVUnit: true)
        var updated = settings.audioUnitPluginChain[index]
        updated.selection = selection
        updated.lastUsedPresetName = nil
        settings.audioUnitPluginChain[index] = updated
        slotRuntimes[id] = SlotRuntime()
        if settings.audioUnitPluginEnabled {
            startSlotLoad(updated)
        } else {
            slotStatuses[id] = .disabled
        }
        rewireGraphSafely()
    }

    func removePluginSlot(id: UUID) {
        tearDownSlot(id: id, detachAVUnit: true)
        slotRuntimes.removeValue(forKey: id)
        slotStatuses.removeValue(forKey: id)
        slotPresets.removeValue(forKey: id)
        slotActivePresetIDs.removeValue(forKey: id)
        settings.audioUnitPluginChain.removeAll { $0.id == id }
        rewireGraphSafely()
    }

    func moveSlot(from source: Int, to destination: Int) {
        var chain = settings.audioUnitPluginChain
        guard source >= 0, source < chain.count,
              destination >= 0, destination <= chain.count,
              source != destination else { return }
        let item = chain.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        chain.insert(item, at: min(target, chain.count))
        settings.audioUnitPluginChain = chain
        rewireGraphSafely()
    }

    func setSlotEnabled(id: UUID, enabled: Bool) {
        guard let index = settings.audioUnitPluginChain.firstIndex(where: { $0.id == id }) else { return }
        settings.audioUnitPluginChain[index].isEnabled = enabled
        rewireGraphSafely()
        recomputeChainStatus()
    }

    func enableAudioUnitPlugin() {
        settings.audioUnitPluginEnabled = true
        // Kick off any slots that didn't load yet.
        for slot in settings.audioUnitPluginChain where slotRuntimes[slot.id]?.avUnit == nil {
            startSlotLoad(slot)
        }
        rewireGraphSafely()
    }

    func disableAudioUnitPlugin() {
        settings.audioUnitPluginEnabled = false
        rewireGraphSafely()
        recomputeChainStatus()
    }

    func bypassAudioUnitPlugin(_ bypassed: Bool) {
        settings.audioUnitPluginBypassed = bypassed
        rewireGraphSafely()
        recomputeChainStatus()
    }

    func openPluginWindow(slotId: UUID) {
        guard let runtime = slotRuntimes[slotId], let avUnit = runtime.avUnit else { return }
        if let existing = runtime.pluginWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let title = settings.audioUnitPluginChain.first(where: { $0.id == slotId })?.selection.name ?? "Plugin"
        avUnit.auAudioUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self, let runtime = self.slotRuntimes[slotId] else { return }
                guard let vc = viewController else {
                    runtime.status = .failed(title, reason: "Plugin editor unavailable")
                    self.slotStatuses[slotId] = runtime.status
                    self.recomputeChainStatus()
                    return
                }
                let wrapper = PluginWindowViewController(pluginVC: vc, player: self, slotId: slotId)
                // Force loadView/viewDidLoad so wrapper.view is sized.
                _ = wrapper.view
                let initialSize: NSSize = wrapper.view.frame.size != .zero
                    ? wrapper.view.frame.size
                    : NSSize(width: 600, height: 400)

                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: initialSize),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = title
                // Each plugin window stays standalone — never auto-merged into a
                // tab group (which would also disable the resize handle). A
                // unique tabbingIdentifier means even if macOS tries to group,
                // there's no other window it could group with.
                window.tabbingMode = .disallowed
                window.tabbingIdentifier = "tangodisplay.plugin.\(slotId.uuidString)"
                window.isRestorable = false
                // Bypass `contentViewController = wrapper` deliberately: that
                // setter binds the window's content size to the VC's
                // preferredContentSize, which silently overrides manual resize
                // and our own setContentSize calls. Setting contentView
                // directly keeps the window freely resizable. We then hold the
                // wrapper VC strongly in SlotRuntime since the window doesn't.
                window.contentView = wrapper.view
                window.contentMinSize = NSSize(width: 200, height: 100)
                window.contentMaxSize = NSSize(width: 4096, height: 4096)
                window.isReleasedWhenClosed = false
                window.center()
                window.makeKeyAndOrderFront(nil)
                // Defensive: if macOS somehow grouped us anyway, break out.
                if window.tabGroup != nil {
                    window.moveTabToNewWindow(nil)
                }
                runtime.pluginWindow = window
                runtime.pluginWindowVC = wrapper
            }
        }
    }

    func closePluginWindow(slotId: UUID) {
        slotRuntimes[slotId]?.pluginWindow?.close()
        slotRuntimes[slotId]?.pluginWindow = nil
        slotRuntimes[slotId]?.pluginWindowVC = nil
    }

    // MARK: - Presets (per slot)

    func applyPreset(_ preset: AudioUnitPreset, toSlot slotId: UUID) {
        guard let runtime = slotRuntimes[slotId],
              let avUnit = runtime.avUnit,
              let manager = runtime.presetManager else { return }
        runtime.isApplyingPreset = true
        do {
            try manager.applyPreset(preset, to: avUnit, originator: runtime.paramObserverToken)
            runtime.activePresetID = preset.id
            slotActivePresetIDs[slotId] = preset.id
            updateSlotPresetName(slotId: slotId, name: preset.name)
        } catch {
            os_log(.error, "TangoDisplay: applyPreset failed: %{public}@", error.localizedDescription)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak runtime] in
            runtime?.isApplyingPreset = false
        }
    }

    func saveCurrentAsPreset(named name: String, forSlot slotId: UUID) throws {
        guard let runtime = slotRuntimes[slotId],
              let avUnit = runtime.avUnit,
              let manager = runtime.presetManager else { return }
        let preset = try manager.savePreset(name: name, from: avUnit)
        let all = manager.factoryPresets(for: avUnit) + manager.userPresets()
        runtime.availablePresets = all
        runtime.activePresetID = preset.id
        slotPresets[slotId] = all
        slotActivePresetIDs[slotId] = preset.id
        updateSlotPresetName(slotId: slotId, name: preset.name)
    }

    func deletePreset(_ preset: AudioUnitPreset, fromSlot slotId: UUID) throws {
        guard let runtime = slotRuntimes[slotId],
              let avUnit = runtime.avUnit,
              let manager = runtime.presetManager else { return }
        try manager.deletePreset(preset)
        let all = manager.factoryPresets(for: avUnit) + manager.userPresets()
        runtime.availablePresets = all
        slotPresets[slotId] = all
        if runtime.activePresetID == preset.id {
            runtime.activePresetID = nil
            slotActivePresetIDs.removeValue(forKey: slotId)
            updateSlotPresetName(slotId: slotId, name: nil)
        }
    }

    private func updateSlotPresetName(slotId: UUID, name: String?) {
        guard let index = settings.audioUnitPluginChain.firstIndex(where: { $0.id == slotId }) else { return }
        settings.audioUnitPluginChain[index].lastUsedPresetName = name
    }

    // MARK: - Private: chain internals

    private func initializePluginStatus() {
        guard !settings.audioUnitPluginChain.isEmpty else {
            audioUnitPluginStatus = .noPluginSelected
            return
        }
        for slot in settings.audioUnitPluginChain {
            if slotRuntimes[slot.id] == nil {
                slotRuntimes[slot.id] = SlotRuntime()
            }
            if !settings.audioUnitPluginEnabled {
                slotStatuses[slot.id] = .disabled
                continue
            }
            if slotRuntimes[slot.id]?.avUnit != nil { continue }
            if pluginManager.isAvailable(slot.selection) {
                startSlotLoad(slot)
            } else {
                slotStatuses[slot.id] = .unavailable(slot.selection.name)
            }
        }
        recomputeChainStatus()
    }

    private func startSlotLoad(_ slot: AudioUnitChainSlot) {
        let runtime = slotRuntimes[slot.id] ?? SlotRuntime()
        slotRuntimes[slot.id] = runtime
        runtime.loadTask?.cancel()
        runtime.loadGeneration += 1
        let gen = runtime.loadGeneration
        let slotId = slot.id
        let selection = slot.selection
        runtime.status = .loading(selection.name)
        slotStatuses[slotId] = runtime.status
        recomputeChainStatus()

        runtime.loadTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            do {
                let avUnit = try await pluginManager.instantiate(selection)
                await MainActor.run { [weak self, weak runtime] in
                    guard let self, let runtime,
                          runtime.loadGeneration == gen,
                          self.settings.audioUnitPluginChain.contains(where: { $0.id == slotId })
                    else { return }
                    self.audioEngine.attach(avUnit)
                    runtime.avUnit = avUnit
                    runtime.status = .active(selection.name)
                    self.slotStatuses[slotId] = runtime.status

                    let manager = AudioUnitPresetManager(for: selection)
                    runtime.presetManager = manager
                    let all = manager.factoryPresets(for: avUnit) + manager.userPresets()
                    runtime.availablePresets = all
                    self.slotPresets[slotId] = all

                    self.installSlotObservers(slotId: slotId, runtime: runtime, avUnit: avUnit)

                    // Apply the track's assigned configuration (or default), falling back to last-used preset.
                    var appliedConfig = false
                    if let entryID = self.currentEntryID,
                       let entry = self.setlist.entries.first(where: { $0.id == entryID }) {
                        let resolvedID = entry.pluginConfigurationID ?? self.configStore.defaultConfigurationID
                        if let configID = resolvedID,
                           let config = self.configStore.configuration(id: configID),
                           let slotState = config.slotStates.first(where: { $0.slotID == slotId }) {
                            self.applySlotState(slotState, to: avUnit, runtime: runtime)
                            appliedConfig = true
                        }
                    }

                    if !appliedConfig {
                        // Restore last-used preset for this slot.
                        let savedName = self.settings.audioUnitPluginChain
                            .first(where: { $0.id == slotId })?.lastUsedPresetName
                        if let savedName, let match = all.first(where: { $0.name == savedName }) {
                            runtime.isApplyingPreset = true
                            try? manager.applyPreset(match, to: avUnit, originator: runtime.paramObserverToken)
                            runtime.activePresetID = match.id
                            self.slotActivePresetIDs[slotId] = match.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak runtime] in
                                runtime?.isApplyingPreset = false
                            }
                        }
                    }

                    self.rewireGraphSafely()
                }
            } catch {
                await MainActor.run { [weak self, weak runtime] in
                    guard let self, let runtime, runtime.loadGeneration == gen else { return }
                    runtime.status = .failed(selection.name, reason: error.localizedDescription)
                    self.slotStatuses[slotId] = runtime.status
                    self.recomputeChainStatus()
                }
            }
        }
    }

    private func installSlotObservers(slotId: UUID, runtime: SlotRuntime, avUnit: AVAudioUnit) {
        if let tree = avUnit.auAudioUnit.parameterTree {
            runtime.paramObserverTree = tree
            runtime.paramObserverToken = tree.token(byAddingParameterObserver: { [weak self, weak runtime] _, _ in
                DispatchQueue.main.async {
                    guard let self, let runtime, !runtime.isApplyingPreset else { return }
                    runtime.activePresetID = nil
                    self.slotActivePresetIDs.removeValue(forKey: slotId)
                    self.updateSlotPresetName(slotId: slotId, name: nil)
                }
            })
        }
        // KVO on currentPreset catches V2 AU UIs (e.g. AUGraphicEQ "Flat") that bypass the parameter tree.
        runtime.currentPresetObservation = avUnit.auAudioUnit.observe(\.currentPreset, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, let runtime = self.slotRuntimes[slotId], !runtime.isApplyingPreset else { return }
                runtime.activePresetID = nil
                self.slotActivePresetIDs.removeValue(forKey: slotId)
                self.updateSlotPresetName(slotId: slotId, name: nil)
            }
        }
    }

    private func teardownSlotObservers(_ runtime: SlotRuntime) {
        if let tree = runtime.paramObserverTree, let token = runtime.paramObserverToken {
            tree.removeParameterObserver(token)
        }
        runtime.paramObserverTree = nil
        runtime.paramObserverToken = nil
        runtime.currentPresetObservation = nil
    }

    private func tearDownSlot(id: UUID, detachAVUnit: Bool) {
        guard let runtime = slotRuntimes[id] else { return }
        runtime.loadTask?.cancel()
        runtime.loadTask = nil
        runtime.pluginWindow?.close()
        runtime.pluginWindow = nil
        runtime.pluginWindowVC = nil
        teardownSlotObservers(runtime)
        if detachAVUnit, let unit = runtime.avUnit {
            audioEngine.disconnectNodeOutput(unit)
            audioEngine.detach(unit)
        }
        runtime.avUnit = nil
        runtime.presetManager = nil
        runtime.availablePresets = []
        runtime.activePresetID = nil
        slotPresets.removeValue(forKey: id)
        slotActivePresetIDs.removeValue(forKey: id)
    }

    private func recomputeChainStatus() {
        let chain = settings.audioUnitPluginChain
        guard !chain.isEmpty else {
            audioUnitPluginStatus = .noPluginSelected
            return
        }
        if !settings.audioUnitPluginEnabled {
            audioUnitPluginStatus = .disabled
            return
        }
        // Surface a failure if any slot is broken.
        if let failed = chain.compactMap({ slot -> (String, String)? in
            if case .failed(let n, let r) = slotStatuses[slot.id] ?? .noPluginSelected {
                return (n, r)
            }
            return nil
        }).first {
            audioUnitPluginStatus = .failed(failed.0, reason: failed.1)
            return
        }
        if settings.audioUnitPluginBypassed {
            audioUnitPluginStatus = .bypassed(chainSummaryName(chain))
            return
        }
        // Loading wins over active so the UI shows progress.
        if chain.contains(where: { if case .loading = slotStatuses[$0.id] ?? .noPluginSelected { return true } else { return false } }) {
            audioUnitPluginStatus = .loading(chainSummaryName(chain))
            return
        }
        audioUnitPluginStatus = .active(chainSummaryName(chain))
    }

    private func chainSummaryName(_ chain: [AudioUnitChainSlot]) -> String {
        if chain.count == 1 { return chain[0].selection.name }
        return "\(chain.count) plugins"
    }

    // MARK: - Private: observers

    private func setupObservers() {
        timeObserverTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateTime() }

        Publishers.CombineLatest4(settings.$autoGapEnabled, settings.$autoGapDuration,
                                  settings.$autoGapMaximumEnabled, settings.$autoGapMaximumDuration)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cancelAutoGapCutoff()
                self?.refreshAutoGapAnalysis()
                self?.checkAutoGapCutoff()
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didUnmountNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setlist.refreshMediaAvailability() }
            .store(in: &cancellables)

        setlist.$mediaIssues
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAutoGapAnalysis() }
            .store(in: &cancellables)

        settings.$builtInOutputDeviceUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in self?.applyOutputDevice(uid) }
            .store(in: &cancellables)

        settings.$builtInHogMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                let uid = self.settings.builtInOutputDeviceUID
                self.isChangingDevice = true
                self.audioDeviceQueue.async {
                    self.applyHogMode(enabled: enabled, deviceUID: uid)
                    DispatchQueue.main.async { self.isChangingDevice = false }
                }
            }
            .store(in: &cancellables)

        settings.$eqBand0Gain.sink { [weak self] v in self?.eq.bands[0].gain = v }.store(in: &cancellables)
        settings.$eqBand1Gain.sink { [weak self] v in self?.eq.bands[1].gain = v }.store(in: &cancellables)
        settings.$eqBand2Gain.sink { [weak self] v in self?.eq.bands[2].gain = v }.store(in: &cancellables)
        settings.$eqBand3Gain.sink { [weak self] v in self?.eq.bands[3].gain = v }.store(in: &cancellables)
        settings.$eqBand4Gain.sink { [weak self] v in self?.eq.bands[4].gain = v }.store(in: &cancellables)

        settings.$builtInBalance
            .dropFirst()
            .sink { [weak self] v in self?.balance = v }
            .store(in: &cancellables)

        // Parameter moves are written straight through, and engagement toggles bypass —
        // neither touches the graph, so restoration never interrupts playback.
        settings.$restoration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r in
                guard let self else { return }
                self.applyRestorationParams(r)
                let entry = self.currentEntryID.flatMap { id in
                    self.setlist.entries.first { $0.id == id }
                }
                let wanted = self.restorationNodes(for: entry)
                if wanted != self.activeRestoration {
                    self.applyRestorationEngagement(wanted)
                }
            }
            .store(in: &cancellables)

        // receive(on: DispatchQueue.main) defers the sink to the next run-loop cycle so that
        // the @Published property (which fires in willSet) is fully committed before we read it.
        settings.$replayGainMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyReplayGainIfLoaded() }
            .store(in: &cancellables)
        settings.$replayGainPreampDb
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyReplayGainIfLoaded() }
            .store(in: &cancellables)
        settings.$replayGainPreventClipping
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyReplayGainIfLoaded() }
            .store(in: &cancellables)
        settings.$replayGainTargetLufs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyReplayGainIfLoaded() }
            .store(in: &cancellables)
        settings.$cortinaVolumeReductionDb
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyReplayGainIfLoaded() }
            .store(in: &cancellables)

        setlist.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let entries = self.setlist.entries
                // Remove early-mark for entries removed from setlist or explicitly unmarked as played.
                let playedIDs = Set(entries.filter { $0.state == .played }.map(\.id))
                self.earlyMarkedEntryIDs.formIntersection(playedIDs)
                // Per-track restoration override on the track that is already playing:
                // act only when engagement actually changed, so ordinary setlist edits
                // don't touch the units.
                if let id = self.currentEntryID {
                    let wanted = self.restorationNodes(for: entries.first { $0.id == id })
                    if wanted != self.activeRestoration {
                        self.applyRestorationEngagement(wanted)
                    }
                }
                if let id = self.currentEntryID, !self.earlyMarkedEntryIDs.contains(id) {
                    self.isCurrentEntryMarkedAsPlayed = false
                }
                if let id = self.currentEntryID,
                   !entries.contains(where: { $0.id == id }) {
                    self.isHeld = false
                    self.scheduleGeneration += 1
                    self.currentEntryID = nil
                    self.isActivePlaying = false
                    self.replayGainStatus = ""
                    self.playerNode.stop()
                    self.audioFile = nil
                    self.elapsed = 0
                    self.duration = 0
                    self.seekOffset = 0
                    self.reportCurrentState()
                    self.reportPlaylist()
                    self.onNextTrackUpdate?(nil)
                }
                if let id = self.currentEntryID, self.audioFile == nil,
                   let entry = entries.first(where: { $0.id == id }),
                   let d = entry.duration, d != self.duration {
                    self.duration = d
                }
                if let id = self.currentEntryID, self.audioFile == nil, !self.isActivePlaying,
                   entries.first(where: { $0.id == id })?.state == .played {
                    if let next = self.setlist.firstUnplayed(after: id) {
                        self.currentEntryID = next.id
                        self.elapsed = 0
                        self.duration = next.duration ?? 0
                        self.reportCurrentState()
                        self.reportPlaylist()
                        self.onNextTrackUpdate?(self.setlist.entry(after: next.id)?.track)
                    } else {
                        self.currentEntryID = nil
                        self.elapsed = 0
                        self.duration = 0
                        self.reportCurrentState()
                        self.reportPlaylist()
                        self.onNextTrackUpdate?(nil)
                    }
                }
                if self.currentEntryID == nil, self.audioFile == nil,
                   let firstQueued = entries.first(where: { $0.state == .queued && self.setlist.isPlayable($0) }) {
                    self.currentEntryID = firstQueued.id
                    self.elapsed = 0
                    self.duration = firstQueued.duration ?? 0
                    self.reportCurrentState()
                    self.reportPlaylist()
                    self.onNextTrackUpdate?(self.setlist.entry(after: firstQueued.id)?.track)
                }
                // A reorder may have inserted a queued track before our queued-but-not-yet-loaded
                // current entry. Promote the new first-queued entry to be the current one.
                if let id = self.currentEntryID, self.audioFile == nil, !self.isActivePlaying,
                   entries.first(where: { $0.id == id })?.state == .queued,
                   let firstQueued = entries.first(where: { $0.state == .queued && self.setlist.isPlayable($0) }),
                   firstQueued.id != id {
                    self.currentEntryID = firstQueued.id
                    self.elapsed = 0
                    self.duration = firstQueued.duration ?? 0
                    self.reportCurrentState()
                    self.reportPlaylist()
                    self.onNextTrackUpdate?(self.setlist.entry(after: firstQueued.id)?.track)
                }
                self.refreshAutoGapAnalysis()
                // Always report so AppState recalculates tanda position on any entries
                // change, including pure reorders that don't trigger any branch above.
                self.reportPlaylist()
            }
            .store(in: &cancellables)
    }

    private func teardownObservers() {
        timeObserverTimer = nil
        cancellables.removeAll()
    }

    // MARK: - Private: time update

    private func updateTime() {
        guard isActivePlaying, !isChangingDevice, engineRecoveryGeneration == nil,
              let file = audioFile else { return }
        let playbackTime: AVAudioTime?
        if playerNode.isPlaying, let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid {
            playbackTime = playerNode.playerTime(forNodeTime: nodeTime)
        } else {
            playbackTime = nil
        }
        if playbackProgress?.hasStalled(sampleTime: playbackTime?.sampleTime,
                                         now: ProcessInfo.processInfo.systemUptime) == true {
            if audioEngine.isRunning {
                recoverPlaybackFailure(PlaybackFailure.track("Playback stopped unexpectedly."))
            } else {
                interruptForUnavailableOutput()
                retryOutputDevice()
            }
            return
        }
        guard let playerTime = playbackTime else { return }

        guard !silencePending else { elapsed = 0; return }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return }
        let audioFrames = max(0, playerTime.sampleTime - AVAudioFramePosition(currentPaddingFrames))
        let newElapsed = seekOffset + Double(audioFrames) / sampleRate
        elapsed = max(0, min(newElapsed, duration))
        duration = Double(file.length) / sampleRate

        if !settings.markAsPlayedAfterCompletion,
           let id = currentEntryID,
           !earlyMarkedEntryIDs.contains(id),
           duration > 0,
           elapsed >= Double(settings.markAsPlayedAfterSeconds) {
            earlyMarkedEntryIDs.insert(id)
            isCurrentEntryMarkedAsPlayed = true
            setlist.markPlayed(id: id)
            reportPlaylist()
        }
        checkAutoGapCutoff()
    }

    /// Re-sends the current track and playlist — for when a row's tags change under the
    /// player (Edit Tags), since nothing here observes `setlist.entries`.
    func refreshReports() {
        reportCurrentState()
        reportPlaylist()
    }

    // MARK: - Private: state reporting

    private func reportCurrentState() {
        guard let id = currentEntryID,
              let entry = setlist.entries.first(where: { $0.id == id })
        else {
            isActivePlaying = false
            onTrackUpdate?(nil, .stopped)
            return
        }
        let state: PlayerState = isActivePlaying ? .playing : .paused
        onTrackUpdate?(entry.track, state)
    }

    private func reportPlaylist() {
        let entries = setlist.entries
        guard !entries.isEmpty else { onPlaylistUpdate(nil); return }
        let tracks = entries.map { $0.track }
        let idx = entries.firstIndex(where: { $0.id == currentEntryID }) ?? 0
        onPlaylistUpdate((tracks: tracks, currentIndex: idx))
    }
}
