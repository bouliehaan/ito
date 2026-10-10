import AVFoundation
import CoreAudio
import Foundation
import ItoObjC
import os

private let log = Logger(subsystem: "app.ito", category: "audio")

/// The Mac's half of a call: microphone out, the other person in.
///
/// Two shapes, chosen when the call starts:
///
/// - Speakers (nothing Bluetooth): one engine with Apple's voice processing (the VPIO
///   unit behind FaceTime): echo cancellation against what the speakers play, noise
///   suppression, AGC. Without it your speakers feed the caller's voice back into your
///   mic and they hear themselves. It has to hear the output, so one engine does both.
/// - Bluetooth headphones or headset: there is no speaker-to-mic echo to cancel, and
///   voice processing on Bluetooth refuses (-10875) or runs with a mic that delivers
///   nothing. Two engines instead: one only listens, one only plays.
///
/// The split is what keeps a Bluetooth headset working. Opening its mic switches the
/// headset from music mode to call mode, which takes seconds, takes the output from
/// 44.1 to 16 kHz and stops whatever engine plays to it. With two engines only the
/// player is rebuilt; the mic stays open through it, so the headset stays in call mode.
/// Closing the mic, even for a moment, sends the headset back to music mode and the
/// next open switches it again: every switch is a chime in your ears and seconds of
/// nothing.
///
/// Every (re)build is a brand new AVAudioEngine. An engine stopped by a device change
/// keeps the old device's format and fails to start forever after (-10868), and one
/// whose voice processing was turned off again has a mic that delivers nothing. Retries
/// and rebuilds carry a generation number, so a stale one never runs and each side has
/// at most one chain of them. A mic that goes quiet for [stallSeconds] is rebuilt;
/// after [maxStalls] the user is told.
///
/// Engine calls that can raise an Objective-C exception go through ITOCatch: a strange
/// device can produce an error, never a crash. Everything but the mic tap runs on the
/// main queue.
///
/// Wire format matches the phone: 16 kHz mono s16le, 320 samples (20 ms) per
/// frame, prefixed by a big-endian u32 sequence number.
public final class CallAudio {
    public enum AudioError: LocalizedError {
        case noInput
        case step(String, Error)
        public var errorDescription: String? {
            switch self {
            case .noInput: return "the Mac's microphone isn't delivering any sound"
            case .step(let s, let e): return "\(s): \((e as NSError).domain) \((e as NSError).code) \(e.localizedDescription)"
            }
        }
    }

    /// Which step failed, so an error names it.
    private func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as AudioError { throw e } catch { throw AudioError.step(name, error) }
    }

    /// Called on the audio thread.
    public var onFrame: (@Sendable (Data) -> Void)?
    /// The mic is up. Main queue, once per call.
    public var onStarted: (() -> Void)?
    /// A side gave up: the mic never delivered, or could not be opened, or nothing plays.
    /// Main queue, at most once per call. Whatever still works keeps running.
    public var onError: ((Error) -> Void)?
    public var muted = false

    /// This call uses Apple's voice processing (one engine) rather than the split.
    public private(set) var voiceProcessing = false
    public private(set) var running = false

    /// Long enough for a Bluetooth headset to finish switching to call mode.
    static let stallSeconds = 6.0
    static let maxStalls = 2

    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Listens; with voice processing it also plays. Not for a Bluetooth headset's mic.
    private var mic: AVAudioEngine?
    /// A Bluetooth headset's mic, read from the HAL instead.
    private var headsetMic: HeadsetMic?
    private var micGen = 0
    /// Plays, when there is no voice processing.
    private var speaker: AVAudioEngine?
    private var speakerGen = 0
    private var player: AVAudioPlayerNode?
    private var playerEngine: AVAudioEngine?
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var micRebuild: DispatchWorkItem?
    private var speakerRebuild: DispatchWorkItem?
    private var stallTimer: Timer?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var stalls = 0
    private var started = false
    private var failed = false
    private var heardAt = DispatchTime(uptimeNanoseconds: 0)  // under lock: the last real mic frame
    private var settling: Timer?

    // Shared with the audio threads, under lock.
    private let lock = NSLock()
    private var pipe: Pipe?
    private var lastMicFrame = DispatchTime.now()
    private var queued = 0
    private var playToken = 0
    private var seq: UInt32 = 0

    public init() {}

    public static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Runs [f] once the mic is delivering and a Bluetooth headset has finished switching
    /// to call mode (its output at the mic's rate, the player rebuilt for it): the moment
    /// a call can connect without the switch, and its tone, landing on its first second.
    /// Without a headset mic nothing switches, so as soon as the mic delivers. Main queue,
    /// once; never if the audio stops first.
    public func whenSettled(_ f: @escaping () -> Void) {
        settling?.invalidate()
        var steady = 0
        settling = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, self.running else { return t.invalidate() }
            lock.lock(); let heard = Double(DispatchTime.now().uptimeNanoseconds - heardAt.uptimeNanoseconds) / 1e9; lock.unlock()
            // Only a headset whose mic is in use switches; its output then runs at the mic's rate.
            let input = Self.defaultDevice(input: true), out = Self.defaultDevice(input: false)
            let switched = !Self.isBluetooth(input) || !Self.isBluetooth(out) || Self.rate(out) == Self.rate(input)
            let playing = self.voiceProcessing || self.speaker?.isRunning == true
            steady = heard < 0.2 && switched && playing ? steady + 1 : 0
            guard steady >= 2 else { return }
            t.invalidate()
            log.notice("settled")
            f()
        }
    }

    /// Starts asynchronously; [onStarted] or [onError] says how it went. Main queue.
    public func start() {
        guard !running else { return }
        running = true
        started = false
        failed = false
        stalls = 0
        let input = Self.defaultDevice(input: true), output = Self.defaultDevice(input: false)
        let bluetooth = Self.isBluetooth(input) || Self.isBluetooth(output)
        voiceProcessing = !bluetooth && !Self.refusesVoiceProcessing.contains(Self.uid(input) ?? "")
        log.notice("start: in \(Self.describe(input), privacy: .public), out \(Self.describe(output), privacy: .public), \(self.voiceProcessing ? "voice processing" : "split engines", privacy: .public)")
        lock.lock(); lastMicFrame = .now(); lock.unlock()
        if !voiceProcessing { openSpeaker(0) }
        openMic(0)
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkMic() }
        // The split's mic is pinned to its device, so it has to be told when you pick another.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.inputChanged() }
        var addr = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener) == noErr {
            inputListener = listener
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        settling?.invalidate()
        settling = nil
        micGen += 1
        speakerGen += 1
        micRebuild?.cancel()
        speakerRebuild?.cancel()
        stallTimer?.invalidate()
        stallTimer = nil
        if let inputListener {
            var addr = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, inputListener)
        }
        inputListener = nil
        if let mic { closeMic(mic) }
        if let speaker { closeSpeaker(speaker) }
        headsetMic?.stop()
        headsetMic = nil
        mic = nil
        speaker = nil
        player = nil
        playerEngine = nil
        lock.lock(); pipe = nil; queued = 0; playToken += 1; lock.unlock()
        log.notice("stop")
    }

    /// Downlink from the phone. Past ~160 ms of backlog new frames are dropped: late audio is worse than lost audio.
    public func play(_ frame: Data) {
        guard running, let player, let engine = playerEngine, engine.isRunning, frame.count == 4 + 640 else { return }
        lock.lock()
        let backlog = queued
        let token = playToken
        lock.unlock()
        guard backlog < 8, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: 320) else { return }
        buf.frameLength = 320
        let dst = buf.floatChannelData![0]
        var peak: Float = 0
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<320 {
                let v = Int16(bitPattern: UInt16(raw[4 + 2 * i]) | UInt16(raw[5 + 2 * i]) << 8)
                dst[i] = Float(v) / 32768
                peak = max(peak, abs(dst[i]))
            }
        }
        // Real sound on the line (early media, an announcement, the person) always wins
        // over the made-up ringback, for the rest of the call.
        if peak > 0.02 { lineHasSound = true }
        if ringback && !lineHasSound { synthRingback(dst) }
        if toneLeft > 0 { mixTone(dst) }
        lock.lock(); queued += 1; lock.unlock()
        // A rebuilt player starts its count from zero; the old one's callbacks must not touch it.
        let done: () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock(); if self.playToken == token { self.queued -= 1 }; self.lock.unlock()
        }
        if !ITOCatch({ player.scheduleBuffer(buf, completionHandler: done) }, nil) { done() }
    }

    // MARK: tones the phone would have played locally

    /// The phone generates ringback itself when the network sends none (Telecom's
    /// RingbackPlayer), so it never travels the call audio. Set while an outgoing call
    /// is dialing; it only sounds while the line itself is silent.
    public var ringback = false {
        didSet { if ringback && !oldValue { ringFrame = 0; lineHasSound = false } }
    }
    private var lineHasSound = false
    private var ringFrame = 0
    private var ringPhase = (0.0, 0.0)

    /// US ringback: 440 + 480 Hz, 2 s on, 4 s off. 50 frames a second.
    private func synthRingback(_ dst: UnsafeMutablePointer<Float>) {
        let on = ringFrame % 300 < 100
        ringFrame += 1
        for i in 0..<320 {
            var v: Float = 0
            if on {
                v = Float(sin(ringPhase.0) + sin(ringPhase.1)) * 0.09
                ringPhase.0 += 2 * .pi * 440 / 16_000
                ringPhase.1 += 2 * .pi * 480 / 16_000
            }
            dst[i] = v
        }
        if !on { ringPhase = (0, 0) }
    }

    private var toneFreqs = (0.0, 0.0)
    private var tonePhase = (0.0, 0.0)
    private var toneLeft = 0

    /// Keypad feedback, so a pressed key sounds like one. 160 ms, matching what the phone sends.
    public func tone(_ key: Character) {
        let rows: [Character: Double] = ["1": 697, "2": 697, "3": 697, "4": 770, "5": 770, "6": 770,
                                         "7": 852, "8": 852, "9": 852, "*": 941, "0": 941, "#": 941]
        let cols: [Character: Double] = ["1": 1209, "4": 1209, "7": 1209, "*": 1209,
                                         "2": 1336, "5": 1336, "8": 1336, "0": 1336,
                                         "3": 1477, "6": 1477, "9": 1477, "#": 1477]
        guard let r = rows[key], let c = cols[key] else { return }
        toneFreqs = (r, c)
        tonePhase = (0, 0)
        toneLeft = 8
    }

    private func mixTone(_ dst: UnsafeMutablePointer<Float>) {
        toneLeft -= 1
        for i in 0..<320 {
            dst[i] += Float(sin(tonePhase.0) + sin(tonePhase.1)) * 0.08
            tonePhase.0 += 2 * .pi * toneFreqs.0 / 16_000
            tonePhase.1 += 2 * .pi * toneFreqs.1 / 16_000
        }
    }

    // MARK: engines

    /// A new engine for the mic (and, with voice processing, the player). On failure it
    /// tries again on another new engine; without voice processing the old engine is
    /// closed only once the new one runs, so the mic is never let go.
    private func openMic(_ attempt: Int) {
        guard running else { return }
        micGen += 1
        let gen = micGen
        if !voiceProcessing && Self.isBluetooth(Self.defaultDevice(input: true)) { return openHeadsetMic(attempt, gen) }
        // Two voice-processing units in one process fight; that path has no Bluetooth to keep in call mode.
        if voiceProcessing, let old = mic { closeMic(old); mic = nil; player = nil; playerEngine = nil }
        let engine = AVAudioEngine()
        let pipe = Pipe(processed: voiceProcessing)
        var node: AVAudioPlayerNode?
        let format: AVAudioFormat
        do {
            let input = engine.inputNode
            if voiceProcessing {
                try step("voice processing") { try input.setVoiceProcessingEnabled(true) }
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                let p = AVAudioPlayerNode()
                try step("player") { try objc {
                    engine.attach(p)
                    engine.connect(p, to: engine.mainMixerNode, format: self.playFormat)
                } }
                node = p
            } else if let unit = input.audioUnit {
                // Left on the default, the engine listens through an aggregate of the default
                // input and output, and the output switching modes knocks the mic over with it.
                var device = Self.defaultDevice(input: true)
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &device, UInt32(MemoryLayout<AudioObjectID>.size))
                if status != noErr { log.error("could not pin the mic to its device: \(status)") }
            }
            format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
            try step("mic tap") { try objc {
                // format nil = exactly what the bus produces now.
                input.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buf, _ in self?.captured(buf, pipe) }
            } }
            engine.prepare()
            try step("mic start") { try engine.start() }
            if let node { try step("playback") { try objc { node.play() } } }
        } catch {
            closeMic(engine)
            log.error("mic attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
            if voiceProcessing && attempt >= 1 { return fallBackFromVoiceProcessing() }
            guard attempt < 15 else { return giveUp(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running, self.micGen == gen else { return }
                self.openMic(attempt + 1)
            }
            return
        }
        let old = mic
        mic = engine
        lock.lock(); self.pipe = pipe; lastMicFrame = .now(); lock.unlock()
        if let old { closeMic(old) }
        headsetMic?.stop()
        headsetMic = nil
        if let node { setPlayer(node, on: engine) }
        observe(engine, mic: true, gen)
        log.notice("mic up (attempt \(attempt)): \(Int(format.sampleRate)) Hz × \(format.channelCount)")
        if !started { started = true; onStarted?() }
    }

    /// A Bluetooth headset's mic, straight from the HAL (see [HeadsetMic]). A new one
    /// starts before the old one stops, so the headset never sees its mic closed.
    private func openHeadsetMic(_ attempt: Int, _ gen: Int) {
        let device = Self.defaultDevice(input: true)
        let pipe = Pipe(processed: false)
        let tap = HeadsetMic(device) { [weak self] buf in self?.captured(buf, pipe) }
        do {
            try tap.start()
        } catch {
            log.error("headset mic attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
            guard attempt < 15 else { return giveUp(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running, self.micGen == gen else { return }
                self.openMic(attempt + 1)
            }
            return
        }
        let old = headsetMic
        headsetMic = tap
        lock.lock(); self.pipe = pipe; lastMicFrame = .now(); lock.unlock()
        old?.stop()
        if let mic { closeMic(mic); self.mic = nil }
        log.notice("mic up (attempt \(attempt)): headset, \(Int(Self.rate(device))) Hz")
        if !started { started = true; onStarted?() }
    }

    /// A new engine that only plays. Never touches its inputNode: that would open the mic.
    private func openSpeaker(_ attempt: Int) {
        guard running, !voiceProcessing else { return }
        speakerGen += 1
        let gen = speakerGen
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        do {
            try step("player") { try objc {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: self.playFormat)
            } }
            engine.prepare()
            try step("speaker start") { try engine.start() }
            try step("playback") { try objc { node.play() } }
        } catch {
            closeSpeaker(engine)
            log.error("speaker attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
            guard attempt < 15 else { return giveUp(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running, self.speakerGen == gen else { return }
                self.openSpeaker(attempt + 1)
            }
            return
        }
        let old = speaker
        speaker = engine
        setPlayer(node, on: engine)
        if let old { closeSpeaker(old) }
        observe(engine, mic: false, gen)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        log.notice("speaker up (attempt \(attempt)): \(Int(rate)) Hz")
    }

    private func closeMic(_ engine: AVAudioEngine) {
        unobserve(engine)
        _ = ITOCatch({
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }, nil)
    }

    private func closeSpeaker(_ engine: AVAudioEngine) {
        unobserve(engine)
        _ = ITOCatch({ engine.stop() }, nil)
    }

    private func setPlayer(_ node: AVAudioPlayerNode, on engine: AVAudioEngine) {
        lock.lock(); playToken += 1; queued = 0; lock.unlock()
        player = node
        playerEngine = engine
    }

    private func observe(_ engine: AVAudioEngine, mic isMic: Bool, _ gen: Int) {
        observers[ObjectIdentifier(engine)] = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.deviceChanged(mic: isMic, gen) }
    }

    private func unobserve(_ engine: AVAudioEngine) {
        if let o = observers.removeValue(forKey: ObjectIdentifier(engine)) { NotificationCenter.default.removeObserver(o) }
    }

    /// The engine's device changed under it, which stops it. Changes come in bursts (a
    /// headset switching modes sends several), so rebuild once they settle, and only if
    /// it really stopped.
    private func deviceChanged(mic isMic: Bool, _ gen: Int) {
        guard running, gen == (isMic ? micGen : speakerGen) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, gen == (isMic ? self.micGen : self.speakerGen) else { return }
            if let e = isMic ? self.mic : self.speaker, e.isRunning { return }
            log.notice("\(isMic ? "mic" : "speaker", privacy: .public) device changed; new engine")
            if isMic { self.openMic(0) } else { self.openSpeaker(0) }
        }
        if isMic { micRebuild?.cancel(); micRebuild = work } else { speakerRebuild?.cancel(); speakerRebuild = work }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// You picked another input mid-call. Voice processing's engine follows the default by itself.
    private func inputChanged() {
        guard running, !voiceProcessing else { return }
        var device = headsetMic?.device ?? 0
        if let unit = mic?.inputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        }
        guard device != Self.defaultDevice(input: true) else { return }
        log.notice("input is now \(Self.describe(Self.defaultDevice(input: true)), privacy: .public); new mic engine")
        micRebuild?.cancel()
        openMic(0)
    }

    /// Once a second: started is not the same as hearing you.
    private func checkMic() {
        guard running, !failed else { return }
        lock.lock(); let quiet = Double(DispatchTime.now().uptimeNanoseconds - lastMicFrame.uptimeNanoseconds) / 1e9; lock.unlock()
        guard quiet > Self.stallSeconds else { return }
        stalls += 1
        log.error("mic delivered nothing for \(Int(quiet)) s (stall \(self.stalls))")
        if stalls > Self.maxStalls { return giveUp(AudioError.noInput) }
        if voiceProcessing { return fallBackFromVoiceProcessing() }
        micRebuild?.cancel()
        openMic(0)
        lock.lock(); lastMicFrame = .now(); lock.unlock()
    }

    /// Voice processing refused twice, or ran with a deaf mic: this input gets the split from now on.
    private func fallBackFromVoiceProcessing() {
        guard running, voiceProcessing else { return }
        voiceProcessing = false
        if let uid = Self.uid(Self.defaultDevice(input: true)) { Self.refusesVoiceProcessing.insert(uid) }
        log.notice("voice processing refused or deaf on this input; split engines")
        if let mic { closeMic(mic) }
        mic = nil
        player = nil
        playerEngine = nil
        lock.lock(); pipe = nil; lastMicFrame = .now(); lock.unlock()
        openSpeaker(0)
        openMic(0)
    }

    private func giveUp(_ error: Error) {
        guard !failed else { return }
        failed = true
        log.error("call audio gave up: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    private func objc(_ block: () -> Void) throws {
        var error: NSError?
        if !ITOCatch(block, &error) { throw error ?? AudioError.noInput }
    }

    // MARK: devices

    private static var refusesVoiceProcessing: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ito.vpRefused") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ito.vpRefused") }
    }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    static func defaultDevice(input: Bool) -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard id != 0, AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The device's persistent UID (survives reconnects, unlike its id).
    static func uid(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    static func isBluetooth(_ id: AudioObjectID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard id != 0, AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func rate(_ id: AudioObjectID) -> Float64 {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func describe(_ id: AudioObjectID) -> String {
        "\(string(id, kAudioObjectPropertyName) ?? "none") @\(Int(rate(id)))\(isBluetooth(id) ? " bluetooth" : "")"
    }

    // MARK: a Bluetooth headset's mic

    /// A Bluetooth headset's mic read straight from the HAL, with an IOProc. An
    /// AVAudioEngine stops itself on every device change, and a headset switching to call
    /// mode changes several times; an engine reopened mid-switch can hang for seconds and
    /// then fail (-10868), and while the mic is closed the headset drops back to music
    /// mode and switches again, tone after tone. An IOProc stays started through the
    /// changes and the HAL hands it the mic in whatever format the device has now. It
    /// is called on its own queue rather than the realtime thread: the conversion
    /// allocates. Only for this: an engine opening a mic an IOProc holds takes seconds.
    private final class HeadsetMic {
        let device: AudioObjectID
        private let deliver: (AVAudioPCMBuffer) -> Void
        private let queue = DispatchQueue(label: "app.ito.headset-mic", qos: .userInteractive)
        private var proc: AudioDeviceIOProcID?
        private var mono: AVAudioPCMBuffer?  // queue

        init(_ device: AudioObjectID, deliver: @escaping (AVAudioPCMBuffer) -> Void) {
            self.device = device
            self.deliver = deliver
        }

        func start() throws {
            var proc: AudioDeviceIOProcID?
            var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                self?.received(input)
            }
            guard status == noErr, let proc else { throw Self.error("open", status) }
            status = AudioDeviceStart(device, proc)
            guard status == noErr else {
                AudioDeviceDestroyIOProcID(device, proc)
                throw Self.error("start", status)
            }
            self.proc = proc
        }

        func stop() {
            guard let proc else { return }
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }

        /// The first channel of the first stream, as mono float at the device's rate.
        private func received(_ input: UnsafePointer<AudioBufferList>) {
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData, first.mNumberChannels > 0 else { return }
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                  mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd) == noErr,
                  asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else { return }
            let channels = Int(first.mNumberChannels)
            let frames = Int(first.mDataByteSize) / (4 * channels)
            guard frames > 0 else { return }
            if mono?.format.sampleRate != asbd.mSampleRate || (mono?.frameCapacity ?? 0) < AVAudioFrameCount(frames) {
                let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false)!
                mono = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
            }
            guard let mono, let dst = mono.floatChannelData?[0] else { return }
            let src = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { dst[i] = src[i * channels] }
            mono.frameLength = AVAudioFrameCount(frames)
            deliver(mono)
        }

        private static func error(_ what: String, _ status: OSStatus) -> Error {
            NSError(domain: "app.ito.headset-mic", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what): \(status)"])
        }
    }

    // MARK: microphone → wire

    /// Conversion state for one mic engine. A new engine gets a new pipe, so a rebuild
    /// never shares a converter with the tap it replaces, and a replaced tap goes silent.
    private final class Pipe {
        /// Voice processing's first channel is the processed voice. Otherwise several
        /// channels are several inputs (a USB interface's 1 and 2), and the mic can be on any.
        let processed: Bool
        init(processed: Bool) { self.processed = processed }
        var converter: AVAudioConverter?
        var from: AVAudioFormat?
        var mono: AVAudioPCMBuffer?
        var carry: [Int16] = []
    }

    private func captured(_ buf: AVAudioPCMBuffer, _ pipe: Pipe) {
        guard buf.frameLength > 0 else { return }
        lock.lock()
        let current = self.pipe === pipe
        if current { lastMicFrame = .now(); heardAt = lastMicFrame }
        lock.unlock()
        guard current else { return }
        // Several channels become one before resampling, so the converter only ever does
        // mono → mono: voice processing's first channel, or else all inputs mixed.
        let source: AVAudioPCMBuffer
        if buf.format.channelCount > 1, let ch = buf.floatChannelData {
            if pipe.mono?.format.sampleRate != buf.format.sampleRate || (pipe.mono?.frameCapacity ?? 0) < buf.frameLength {
                let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false)!
                pipe.mono = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: max(buf.frameLength, 4096))
            }
            guard let m = pipe.mono else { return }
            let n = Int(buf.frameLength)
            m.frameLength = buf.frameLength
            let dst = m.floatChannelData![0]
            dst.update(from: ch[0], count: n)
            if !pipe.processed {
                let count = Int(buf.format.channelCount)
                for c in 1..<count { for i in 0..<n { dst[i] += ch[c][i] } }
                let scale = 1 / Float(count)
                for i in 0..<n { dst[i] *= scale }
            }
            source = m
        } else {
            source = buf
        }
        if pipe.from != source.format {
            pipe.converter = AVAudioConverter(from: source.format, to: wire)
            pipe.from = source.format
        }
        guard let conv = pipe.converter else { return }
        let cap = AVAudioFrameCount(Double(source.frameLength) * 16_000 / source.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        // .noDataNow (not .endOfStream) keeps the resampler's state between taps.
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        pipe.carry.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        while pipe.carry.count >= 320 {
            lock.lock(); let n = seq; seq &+= 1; lock.unlock()
            var frame = Data(capacity: 4 + 640)
            withUnsafeBytes(of: n.bigEndian) { frame.append(contentsOf: $0) }
            if muted {
                frame.append(Data(count: 640))
            } else {
                for s in pipe.carry[0..<320] { withUnsafeBytes(of: s.littleEndian) { frame.append(contentsOf: $0) } }
            }
            pipe.carry.removeFirst(320)
            onFrame?(frame)
        }
    }
}
