import AVFoundation
import Foundation

/// The Mac's half of a call: microphone out, the other person in.
///
/// Voice processing is Apple's own (the VPIO unit behind FaceTime): echo
/// cancellation against what the speakers play, noise suppression, AGC. That
/// matters more than anything else here. Without it, your speakers feed the
/// caller's voice back into your mic and they hear themselves.
///
/// Wire format matches the phone: 16 kHz mono s16le, 320 samples (20 ms) per
/// frame, prefixed by a big-endian u32 sequence number.
public final class CallAudio {
    /// Called on the audio thread.
    public var onFrame: (@Sendable (Data) -> Void)?
    public var muted = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var carry: [Int16] = []
    private var seq: UInt32 = 0
    private let lock = NSLock()
    private var queued = 0
    private var attached = false
    public private(set) var running = false

    public init() {}

    public static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let hw = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hw, to: wire)
        carry.removeAll()
        seq = 0
        input.installTap(onBus: 0, bufferSize: 960, format: hw) { [weak self] buf, _ in self?.captured(buf) }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    public func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        lock.lock(); queued = 0; lock.unlock()
    }

    /// Downlink from the phone. Past ~160 ms of backlog new frames are dropped: late audio is worse than lost audio.
    public func play(_ frame: Data) {
        guard running, frame.count == 4 + 640 else { return }
        lock.lock()
        let backlog = queued
        lock.unlock()
        guard backlog < 8, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: 320) else { return }
        buf.frameLength = 320
        let dst = buf.floatChannelData![0]
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<320 {
                let v = Int16(bitPattern: UInt16(raw[4 + 2 * i]) | UInt16(raw[5 + 2 * i]) << 8)
                dst[i] = Float(v) / 32768
            }
        }
        lock.lock(); queued += 1; lock.unlock()
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }

    private func captured(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        // .noDataNow (not .endOfStream) keeps the resampler's state between taps.
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
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
