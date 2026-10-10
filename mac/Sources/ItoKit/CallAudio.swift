import AVFoundation
import CoreAudio
import Foundation
import ItoObjC

/// The Mac's half of a call: microphone out, the other person in.
///
/// Voice processing is Apple's own (the VPIO unit behind FaceTime): echo
/// cancellation against what the speakers play, noise suppression, AGC. That
/// matters more than anything else here. Without it, your speakers feed the
/// caller's voice back into your mic and they hear themselves.
///
/// Devices move under us. Opening the mic flips Bluetooth headphones from music
/// mode to call mode, which changes the input format mid-setup and stops the
/// engine. So: the mic tap always takes whatever format the device delivers
/// right then, every AVAudioEngine call that can raise an Objective-C exception
/// goes through ITOCatch, and a configuration change rebuilds the graph instead
/// of leaving it dead. A strange device can produce an error, never a crash.
///
/// Wire format matches the phone: 16 kHz mono s16le, 320 samples (20 ms) per
/// frame, prefixed by a big-endian u32 sequence number.
public final class CallAudio {
    public enum AudioError: LocalizedError {
        case noInput
        case step(String, Error)
        public var errorDescription: String? {
            switch self {
            case .noInput: return "no microphone input available"
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
    /// A rebuild after a device change failed. Main queue.
    public var onError: ((Error) -> Void)?
    public var muted = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var attached = false
    private var observer: NSObjectProtocol?
    private var rebuild: DispatchWorkItem?

    // Audio-thread state.
    private var converter: AVAudioConverter?
    private var converterFrom: AVAudioFormat?
    private var mono: AVAudioPCMBuffer?
    private var carry: [Int16] = []
    private var seq: UInt32 = 0

    private let lock = NSLock()
    private var queued = 0
    public private(set) var running = false

    public init() {}

    public static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Starts asynchronously. Opening the mic of a Bluetooth headset switches the whole
    /// headset from music mode to call mode, which takes a second or two, and the voice
    /// processor cannot start against a device that is mid-switch (-10875). So keep
    /// trying for ~5 s. [onStarted] or [onError] says how it ended. Main queue.
    public var onStarted: (() -> Void)?

    /// Apple's voice processing (echo cancellation) is used when the devices allow it.
    /// Some refuse outright: a Bluetooth headset whose mic is in call mode while its output
    /// still reports music mode fails with -10875 every time. Headphones have no
    /// speaker-to-mic echo to cancel, so then the plain engine is the right answer.
    public private(set) var voiceProcessing = true

    public func start() {
        guard !running else { return }
        running = true
        // A device that refused once refuses every time; do not spend the first seconds of a call finding out again.
        voiceProcessing = !Self.refusesVoiceProcessing.contains(Self.defaultInputUID() ?? "")
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.scheduleRebuild() }
        attempt(0)
    }

    private func attempt(_ n: Int) {
        guard running else { return }
        do {
            try configure()
            onStarted?()
        } catch {
            _ = ITOCatch({
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }, nil)
            if voiceProcessing && n >= 2 {
                // Refused three times in a row: not a transient switch. Go without it.
                voiceProcessing = false
                if let uid = Self.defaultInputUID() { Self.refusesVoiceProcessing.insert(uid) }
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attempt(0) }
            } else if n < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.attempt(n + 1) }
            } else {
                stop()
                onError?(error)
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        rebuild?.cancel()
        teardown()
    }

    /// Downlink from the phone. Past ~160 ms of backlog new frames are dropped: late audio is worse than lost audio.
    public func play(_ frame: Data) {
        guard running, engine.isRunning, frame.count == 4 + 640 else { return }
        lock.lock()
        let backlog = queued
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
        let scheduled = ITOCatch({
            self.player.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.queued -= 1; self.lock.unlock()
            }
        }, nil)
        if !scheduled { lock.lock(); queued -= 1; lock.unlock() }
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

    // MARK: graph

    private func configure() throws {
        let input = engine.inputNode
        if voiceProcessing {
            if !input.isVoiceProcessingEnabled { try step("voice processing") { try input.setVoiceProcessingEnabled(true) } }
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        try step("player") { try objc {
            if !self.attached {
                self.engine.attach(self.player)
                self.attached = true
            }
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: self.playFormat)
        } }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
        try step("mic tap") { try objc {
            input.removeTap(onBus: 0)
            // format nil = exactly what the bus produces now; never a stale guess.
            input.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buf, _ in self?.captured(buf) }
        } }
        engine.prepare()
        try step("engine start") { try engine.start() }
        try step("playback") { try objc { self.player.play() } }
        lock.lock(); queued = 0; lock.unlock()
    }

    private func teardown() {
        _ = ITOCatch({
            self.engine.inputNode.removeTap(onBus: 0)
            self.player.stop()
            self.engine.stop()
        }, nil)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        lock.lock(); queued = 0; lock.unlock()
    }

    /// Device changes come in bursts (a headset switching profiles sends several). Rebuild once, after they settle.
    private func scheduleRebuild() {
        guard running else { return }
        rebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            _ = ITOCatch({
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }, nil)
            self.attempt(0)
        }
        rebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static var refusesVoiceProcessing: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ito.vpRefused") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ito.vpRefused") }
    }

    /// The current default input device's persistent UID (survives reconnects, unlike its id).
    static func defaultInputUID() -> String? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func objc(_ block: () -> Void) throws {
        var error: NSError?
        if !ITOCatch(block, &error) { throw error ?? AudioError.noInput }
    }

    // MARK: microphone → wire

    private func captured(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0 else { return }
        // Voice processing can report several channels; the processed voice is the first.
        // Take it alone, so the converter only ever resamples mono → mono.
        let source: AVAudioPCMBuffer
        if buf.format.channelCount > 1, let ch = buf.floatChannelData {
            if mono?.format.sampleRate != buf.format.sampleRate || (mono?.frameCapacity ?? 0) < buf.frameLength {
                let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false)!
                mono = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: max(buf.frameLength, 4096))
            }
            guard let m = mono else { return }
            m.frameLength = buf.frameLength
            m.floatChannelData![0].update(from: ch[0], count: Int(buf.frameLength))
            source = m
        } else {
            source = buf
        }
        if converterFrom != source.format {
            converter = AVAudioConverter(from: source.format, to: wire)
            converterFrom = source.format
        }
        guard let conv = converter else { return }
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
        carry.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        while carry.count >= 320 {
            var frame = Data(capacity: 4 + 640)
            withUnsafeBytes(of: seq.bigEndian) { frame.append(contentsOf: $0) }
            seq &+= 1
            if muted {
                frame.append(Data(count: 640))
            } else {
                for s in carry[0..<320] { withUnsafeBytes(of: s.littleEndian) { frame.append(contentsOf: $0) } }
            }
            carry.removeFirst(320)
            onFrame?(frame)
        }
    }
}
