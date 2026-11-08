@preconcurrency import AVFoundation
import Foundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// Live microphone capture into a take, through AVAudioEngine.
///
/// The microphone runs at the hardware's rate (48 or 44.1 kHz on most devices); the session
/// converts it to 16 kHz with the engine's deterministic resampler, so the samples the model sees
/// are the same bits on every device. Audio arrives in 10 ms buffers: the stream runs the front
/// end just before each chunk's window completes, which lands in time only when audio arrives in
/// small pieces.
///
/// - iOS: the audio session asks for 10 ms I/O buffers and the engine's input is tapped. While
///   sharing is on it also asks for 48 kHz (the rate shared sessions are coded at), so external
///   routes that can deliver it natively do. A host that manages its own `AVAudioSession` and
///   feeds the session itself keeps its own settings; it can call `setPreferredSampleRate(48_000)`
///   for the same effect.
/// - macOS: there is no audio session. An input tap on the Mac delivers 100 ms buffers whatever
///   size is asked for, so the input goes to an `AVAudioSinkNode` instead, with this process's
///   I/O buffer of the input device set to 10 ms (a per-process setting; other apps keep theirs).
///   The device's sample rate is a system-wide setting shared with every other app, so the SDK
///   never changes it, sharing or not: shared audio at another rate is resampled to 48 kHz for
///   sharing only, as on iOS.
///
/// A hardware rate the engine's resampler does not take (96 or 88.2 kHz audio interfaces, for
/// example) is first converted to 48 kHz with `AVAudioConverter`. Live microphone audio is not
/// reproducible anyway, and the session (and a recording) sees the 48 kHz audio.
///
/// Permission: `Microphone.requestPermission()` asks the user (iOS and macOS show their own
/// dialog, with the app's `NSMicrophoneUsageDescription`); `start` asks too when the user has not
/// been asked yet, and throws `microphoneUnavailable` when access was denied, because a denied
/// microphone delivers silence rather than failing. A sandboxed Mac app also needs the
/// `com.apple.security.device.audio-input` entitlement (the same key serves the hardened runtime).
public final class Microphone: @unchecked Sendable {
    /// Whether the app may record.
    public enum Permission: Sendable, Equatable {
        case granted
        case denied
        /// The user has not been asked yet.
        case undetermined
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    #if os(macOS)
    private var sink: AVAudioSinkNode?
    #endif

    public init() {}

    /// The app's microphone permission now.
    public static var permission: Permission {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
        #else
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .undetermined: return .undetermined
            default: return .denied
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .undetermined: return .undetermined
        default: return .denied
        }
        #endif
    }

    /// Asks the user for the microphone when they have not been asked yet; true when the app
    /// may record.
    public static func requestPermission() async -> Bool {
        #if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        if #available(iOS 17.0, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        #endif
    }

    /// Starts capture into `session` (a `TajweedRecognizer` with an open take).
    public func start(into session: any AudioBufferSink) throws(RecognizerError) {
        if Self.permission == .denied {
            throw .microphoneUnavailable("access to the microphone was denied (Settings, Privacy, Microphone)")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement)
            try? audio.setPreferredIOBufferDuration(0.01)
            if Contributions.isActive { try? audio.setPreferredSampleRate(48_000) }
            try audio.setActive(true)
        } catch {
            throw .microphoneUnavailable("cannot configure the audio session: \(error.localizedDescription)")
        }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw .microphoneUnavailable("no audio input device")
        }
        let adapter = try RateAdapter(format)
        #if os(macOS)
        if let au = input.audioUnit {
            // this process's I/O buffer on the input device: 10 ms (the device keeps its rate)
            var frames = UInt32((format.sampleRate / 100).rounded())
            _ = AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                     &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        // the render callback copies the I/O buffer and returns; the session is fed on a queue
        let queue = DispatchQueue(label: "ai.quranlab.microphone", qos: .userInteractive)
        let node = AVAudioSinkNode { _, frames, list -> OSStatus in
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
            copy.frameLength = frames
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (s, d) in zip(src, dst) where s.mData != nil && d.mData != nil {
                memcpy(d.mData!, s.mData!, Int(min(s.mDataByteSize, d.mDataByteSize)))
            }
            let box = UncheckedBox(copy)
            queue.async { adapter.feed(box.value, into: session) }
            return noErr
        }
        engine.attach(node)
        engine.connect(input, to: node, format: format)
        sink = node
        #else
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 100), format: format) { buffer, _ in
            adapter.feed(buffer, into: session)
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
        } catch {
            detach()
            throw .microphoneUnavailable("cannot start the microphone: \(error.localizedDescription)")
        }
        running = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        engine.stop()
        detach()
        running = false
    }

    private func detach() {
        #if os(macOS)
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
            self.sink = nil
        }
        #else
        engine.inputNode.removeTap(onBus: 0)
        #endif
    }
}

/// Microphone buffers into a session: as they are when the engine's resampler takes their rate,
/// else converted to 48 kHz first (AVAudioConverter, streaming, its state kept across buffers).
/// Called on one thread at a time (the tap's, or the Mac's feeding queue).
final class RateAdapter: @unchecked Sendable {
    let input: AVAudioFormat
    let output: AVAudioFormat
    private let converter: AVAudioConverter?

    init(_ format: AVAudioFormat) throws(RecognizerError) {
        input = format
        if SampleRateConverter.rates.contains(Int(format.sampleRate)), Double(Int(format.sampleRate)) == format.sampleRate {
            output = format
            converter = nil
            return
        }
        guard let out = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: format.channelCount),
              let c = AVAudioConverter(from: format, to: out) else {
            throw .unsupportedAudioFormat("the microphone runs at \(Int(format.sampleRate)) Hz and cannot be converted")
        }
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        output = out
        converter = c
    }

    var converts: Bool { converter != nil }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / input.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        // the input block runs synchronously inside convert, once per call with data
        let given = Locked(false)
        let box = UncheckedBox(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if given.withLock({ g in defer { g = true }; return g }) {
                state.pointee = .noDataNow
                return nil
            }
            state.pointee = .haveData
            return box.value
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    func feed(_ buffer: AVAudioPCMBuffer, into session: any AudioBufferSink) {
        guard let b = convert(buffer) else { return }
        try? session.enqueue(b)
    }
}

/// The kind of audio input a session came from, for the shared session's header: never a device
/// name. "built_in", "wired", "usb", "bluetooth", "car", "continuity", "other", or "unknown". On
/// the Mac it is the default input device's transport type (a headset on the Mac's own jack is
/// "built_in" there: Core Audio does not tell it apart).
enum AudioRoute {
    static func current() -> String {
        #if os(iOS)
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType else { return "unknown" }
        return kind(port)
        #elseif os(macOS)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return "unknown" }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return "unknown" }
        return kind(transport: transport)
        #else
        return "unknown"
        #endif
    }

    #if os(macOS)
    static func kind(transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built_in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            return "wired"
        case 0x6363_7764, 0x6363_776C, 0x6363_6170:   // 'ccwd', 'ccwl', 'ccap': Continuity Capture (an iPhone)
            return "continuity"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default: return "other"
        }
    }
    #endif

    #if os(iOS)
    static func kind(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInMic: return "built_in"
        case .headsetMic, .lineIn: return "wired"
        case .usbAudio: return "usb"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "bluetooth"
        case .carAudio: return "car"
        default:
            if #available(iOS 17, *), port == .continuityMicrophone { return "continuity" }
            return "other"
        }
    }
    #endif
}
