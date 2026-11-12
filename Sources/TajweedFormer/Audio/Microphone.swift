@preconcurrency import AVFoundation
import Foundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// What `listen` needs from a microphone: the SDK's `Microphone`, or a fake in tests.
protocol CaptureDevice: AnyObject, Sendable {
    /// Asks for the permission when it was not asked yet; false when it is refused.
    func authorize() async -> Bool
    /// Opens the input and delivers mono samples with the rate they have; `notice` says what happens to the input.
    func open(deliver: @escaping @Sendable ([Float], Double) -> Void,
              notice: @escaping @Sendable (CaptureNotice) -> Void) throws(RecognizerError)
    /// Stops capture and releases the input. Nothing is delivered after it returns.
    func close()
}

/// What happened to the input of a `listen` take.
enum CaptureNotice: Sendable, Equatable {
    /// A call, or another app took the audio: nothing is read until it ends.
    case interruptionBegan
    /// The interruption ended; `canResume` when the input runs again.
    case interruptionEnded(canResume: Bool)
    /// Another input (headphones in or out): the input was reopened, possibly at another rate.
    case routeChanged
    /// The app left the foreground.
    case background
    /// The input could not be reopened.
    case failed(String)
}

/// The source of a `listen` take: the device stops when the take ends.
final class LiveCapture: SessionSource {
    private let device: any CaptureDevice
    init(_ device: any CaptureDevice) { self.device = device }
    func stop() { device.close() }
}

/// The SDK's microphone, through AVAudioEngine. `model.listen()` uses it; an app that wants samples only uses it
/// directly:
///
///     let microphone = Microphone()
///     for await samples in try await microphone.samples() { meter(samples) }   // mono, at microphone.sampleRate
///
/// The input runs at the hardware's rate (48 or 44.1 kHz on most devices) and that rate travels with the samples, so
/// the Session converts it for the model itself and shared recordings keep the full band. Audio arrives in pieces
/// of about 10 ms.
///
/// - iOS: the audio session is set to record, with 10 ms I/O buffers. An interruption (a call, another app taking
///   the audio) pauses capture until it ends; a route change (headphones in or out) reopens the input at its new
///   rate; the app going to the background ends a `listen` take.
/// - macOS: there is no audio session and no interruption. A change of the input device reopens the input at its
///   new rate (the same event as a route change on iOS). A Mac app that is not frontmost is not suspended, so a
///   `listen` take goes on until it is finished. The device's sample rate is a system-wide setting, so the SDK
///   never changes it.
///
/// A rate the engine's resampler does not take (96 or 88.2 kHz interfaces) is converted to 48 kHz first.
///
/// Permission: the first use asks the user (the system's dialog, with the app's `NSMicrophoneUsageDescription`);
/// a refusal is the error `microphone_denied`. A sandboxed or hardened Mac app also needs the
/// `com.apple.security.device.audio-input` entitlement.
public final class Microphone: @unchecked Sendable {
    /// Whether the app may record.
    enum Permission: Sendable, Equatable {
        case granted
        case denied
        /// The user has not been asked yet.
        case undetermined
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    private var paused = false
    private var rate = 0.0
    private var deliver: (@Sendable ([Float], Double) -> Void)?
    private var notice: (@Sendable (CaptureNotice) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastReopen = Date.distantPast
    private var stream: AsyncStream<[Float]>.Continuation?
    #if os(macOS)
    private var sink: AVAudioSinkNode?
    #endif

    public init() {}

    /// The rate of the samples, in Hz: the device's own (48000 or 44100 on most), or 48000 where that is converted.
    /// 0 before the input is open. It can change when the input device changes.
    public var sampleRate: Double {
        lock.lock()
        defer { lock.unlock() }
        return rate
    }

    /// The most buffers that wait unread on `samples()` (a few seconds of audio).
    static let waitingBuffers = 256

    /// The stream `samples()` hands out: a reader that falls behind loses the oldest waiting buffers, so what waits
    /// never grows past `waitingBuffers`.
    static func stream() -> (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) {
        AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(waitingBuffers))
    }

    /// Asks for the permission when needed, opens the input and gives its samples: mono, -1...1, at `sampleRate`.
    /// The stream ends at `stop()`. Throws `microphone_denied` or `microphone_unavailable`. Read it as it comes: at
    /// most 256 buffers wait, and the oldest waiting one is dropped when the app reads late.
    public func samples() async throws(TajweedError) -> AsyncStream<[Float]> {
        guard await authorize() else { throw TajweedError(.microphoneDenied) }
        let (out, c) = Self.stream()
        do throws(RecognizerError) {
            try open(deliver: { s, _ in _ = c.yield(s) }, notice: { n in
                if case .failed = n { c.finish() }
            })
        } catch {
            c.finish()
            throw TajweedError(from: error)
        }
        keep(c)
        return out
    }

    private func keep(_ c: AsyncStream<[Float]>.Continuation) {
        lock.lock()
        stream = c
        lock.unlock()
    }

    /// Stops capture and releases the input.
    public func stop() { close() }

    /// The app's microphone permission now.
    static var permission: Permission {
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

    /// Asks the user for the microphone when they have not been asked yet; true when the app may record.
    static func requestPermission() async -> Bool {
        #if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        if #available(iOS 17.0, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        #endif
    }

    // MARK: the engine (callers hold the lock)

    /// Reads the input's format and starts the engine on it.
    private func startEngine() throws(RecognizerError) {
        guard let deliver else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw .microphoneUnavailable("no audio input device")
        }
        let adapter = try RateAdapter(format)
        rate = adapter.output.sampleRate
        #if os(macOS)
        if let au = input.audioUnit {
            // this process's I/O buffer on the input device: 10 ms (the device keeps its rate)
            var frames = UInt32((format.sampleRate / 100).rounded())
            _ = AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                     &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        // the render callback copies the I/O buffer and returns; the samples go out on a queue
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
            queue.async { adapter.feed(box.value, to: deliver) }
            return noErr
        }
        engine.attach(node)
        engine.connect(input, to: node, format: format)
        sink = node
        #else
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 100), format: format) { buffer, _ in
            adapter.feed(buffer, to: deliver)
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
        } catch {
            detach()
            throw .microphoneUnavailable("cannot start the microphone: \(error.localizedDescription)")
        }
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

    // MARK: what happens to the input

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.reopen()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = AVAudioSession.InterruptionOptions(rawValue: (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            if type == .began { self?.interruptionBegan() } else if type == .ended { self?.interruptionEnded(resume: options.contains(.shouldResume)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { self?.reopen() }
        })
        observers.append(center.addObserver(forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil,
                                            queue: nil) { [weak self] _ in
            self?.send(.background)
        })
        #endif
    }

    private func send(_ n: CaptureNotice) {
        lock.lock()
        let notice = running ? self.notice : nil
        lock.unlock()
        notice?(n)
    }

    private func interruptionBegan() {
        lock.lock()
        let was = running && !paused
        if was {
            paused = true
            engine.pause()
        }
        lock.unlock()
        if was { send(.interruptionBegan) }
    }

    private func interruptionEnded(resume: Bool) {
        lock.lock()
        guard running, paused else { lock.unlock(); return }
        var resumed = false
        if resume {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            resumed = (try? engine.start()) != nil
        }
        if resumed { paused = false }
        lock.unlock()
        send(.interruptionEnded(canResume: resumed))
    }

    /// The input changed (another device, another format): the engine is started again on the input as it is now.
    private func reopen() {
        lock.lock()
        guard running, !paused, Date().timeIntervalSince(lastReopen) > 0.5 else { lock.unlock(); return }
        lastReopen = Date()
        engine.stop()
        detach()
        var failure: String?
        do throws(RecognizerError) { try startEngine() } catch { failure = "\(error)" }
        lock.unlock()
        send(failure.map { CaptureNotice.failed($0) } ?? CaptureNotice.routeChanged)
    }
}

extension Microphone: CaptureDevice {
    func authorize() async -> Bool {
        switch Self.permission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await Self.requestPermission()
        }
    }

    func open(deliver: @escaping @Sendable ([Float], Double) -> Void,
              notice: @escaping @Sendable (CaptureNotice) -> Void) throws(RecognizerError) {
        if Self.permission == .denied {
            throw .microphoneUnavailable(TajweedError.deniedMark + " (Settings, Privacy, Microphone)")
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
        self.deliver = deliver
        self.notice = notice
        do throws(RecognizerError) { try startEngine() } catch {
            self.deliver = nil
            self.notice = nil
            throw error
        }
        running = true
        paused = false
        observe()
    }

    func close() {
        lock.lock()
        let was = running
        if was {
            engine.stop()
            detach()
            running = false
            paused = false
            rate = 0
        }
        deliver = nil
        notice = nil
        let old = observers
        observers = []
        let c = stream
        stream = nil
        lock.unlock()
        for o in old { NotificationCenter.default.removeObserver(o) }
        c?.finish()
        #if os(iOS)
        if was { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }
}

/// Microphone buffers on their way out: as they are when the engine's resampler takes their rate, else converted to
/// 48 kHz first (AVAudioConverter, streaming, its state kept across buffers). Called on one thread at a time (the
/// tap's, or the Mac's feeding queue).
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

    /// The buffer's samples, mono, with the rate they have after the adapter.
    func feed(_ buffer: AVAudioPCMBuffer, to deliver: ([Float], Double) -> Void) {
        guard let b = convert(buffer), let out = try? AudioFormat.samples(from: b), !out.samples.isEmpty else { return }
        deliver(out.samples, out.rate)
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
