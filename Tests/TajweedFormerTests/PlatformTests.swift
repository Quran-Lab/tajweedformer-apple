@preconcurrency import AVFoundation
import Foundation
import Security
import XCTest
@testable import TajweedFormer

/// What differs between iOS and macOS: the storage folder, the keychain the SDK's items go to, the
/// microphone's rate adapter and the Mac's input route.
final class PlatformTests: XCTestCase {
    func testDefaultStorageIsPerAppOnTheMac() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        let a = QuranLab.Configuration.defaultStorage(applicationSupport: base, bundleID: "com.example.a", processName: "A")
        let b = QuranLab.Configuration.defaultStorage(applicationSupport: base, bundleID: "com.example.b", processName: "B")
        let tool = QuranLab.Configuration.defaultStorage(applicationSupport: base, bundleID: nil, processName: "my tool")
        #if os(macOS)
        XCTAssertEqual(a.path, "/Users/x/Library/Application Support/com.example.a/QuranLab")
        XCTAssertEqual(b.path, "/Users/x/Library/Application Support/com.example.b/QuranLab")
        XCTAssertEqual(tool.path, "/Users/x/Library/Application Support/my_tool/QuranLab")
        #else
        XCTAssertEqual(a.path, "/Users/x/Library/Application Support/QuranLab")
        XCTAssertEqual(a, b)
        XCTAssertEqual(tool, a)
        #endif
    }

    /// Every keychain item the SDK writes goes to the data protection keychain: per app, the
    /// accessibility class honoured, on the Mac as on iOS (never the Mac's login keychain).
    func testKeychainItemsUseTheDataProtectionKeychain() {
        for q in [KeychainAttestKeyStore().query, Contributor.query(), TokenProvider.teamIDProbeQuery] {
            XCTAssertEqual(q[kSecUseDataProtectionKeychain as String] as? Bool, true, "\(q)")
            XCTAssertEqual(q[kSecAttrService as String] as? String, "quranlab.sdk")
        }
    }

    /// A test binary has no team: the data protection keychain refuses it, the contributor id
    /// falls back to a file in the SDK's storage, and no team id is found (so no App Attest).
    func testWithoutEntitlementsTheContributorFallsBackToAFile() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("zf-plat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        let id = try XCTUnwrap(Contributor.id(storage: storage))
        XCTAssertEqual(id.count, 32)
        XCTAssertEqual(Contributor.id(storage: storage), id)
        XCTAssertNil(TokenProvider.teamIDFromKeychain())
        XCTAssertFalse(DeviceCheckAttester().isSupported && TokenProvider.teamIDFromKeychain() != nil)
        Contributor.reset(storage: storage)
        XCTAssertNotEqual(Contributor.id(storage: storage), id)
    }

    func testRateAdapterPassesSupportedRatesThrough() throws {
        for rate in [16_000.0, 44_100, 48_000] {
            let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let a = try RateAdapter(f)
            XCTAssertFalse(a.converts)
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 160)!
            b.frameLength = 160
            XCTAssertTrue(a.convert(b) === b)
        }
    }

    /// A 96 kHz interface: converted to 48 kHz as it streams, in 10 ms pieces, the length kept
    /// (the converter's latency aside) and the tone intact.
    func testRateAdapterConverts96kHzTo48kHz() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1)!
        let a = try RateAdapter(f)
        XCTAssertTrue(a.converts)
        XCTAssertEqual(a.output.sampleRate, 48_000)
        var out: [Float] = []
        var t = 0
        for _ in 0..<200 {   // 2 s
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 960)!
            b.frameLength = 960
            for i in 0..<960 { b.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(t + i) / 96_000) }
            t += 960
            if let c = a.convert(b) {
                XCTAssertEqual(c.format.sampleRate, 48_000)
                out += Array(UnsafeBufferPointer(start: c.floatChannelData![0], count: Int(c.frameLength)))
            }
        }
        XCTAssertEqual(Double(out.count), 96_000, accuracy: 200)
        let steady = out[24_000..<72_000]
        let peak = steady.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.5, accuracy: 0.01)
    }

    final class Sink: AudioBufferSink, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seconds = 0.0
        private(set) var rates: Set<Double> = []
        func enqueue(_ b: AVAudioPCMBuffer) throws(RecognizerError) {
            lock.lock()
            seconds += Double(b.frameLength) / b.format.sampleRate
            rates.insert(b.format.sampleRate)
            lock.unlock()
        }
    }

    /// Converted microphone audio reaches the take at 48 kHz, which the engine's resampler takes.
    func testRateAdapterFeedsASink() throws {
        let sink = Sink()
        let f = AVAudioFormat(standardFormatWithSampleRate: 88_200, channels: 2)!
        let a = try RateAdapter(f)
        for _ in 0..<150 {   // 1.5 s
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 882)!
            b.frameLength = 882
            a.feed(b, into: sink)
        }
        XCTAssertEqual(sink.seconds, 1.5, accuracy: 0.02)
        XCTAssertEqual(sink.rates, [48_000])
    }

    #if os(macOS)
    func testMacInputRouteKinds() {
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeBuiltIn), "built_in")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeUSB), "usb")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeBluetooth), "bluetooth")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeBluetoothLE), "bluetooth")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeThunderbolt), "wired")
        XCTAssertEqual(AudioRoute.kind(transport: 0x6363_776C), "continuity")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeVirtual), "other")
        XCTAssertEqual(AudioRoute.kind(transport: kAudioDeviceTransportTypeUnknown), "unknown")
        // whatever this machine has, never a device name
        let now = AudioRoute.current()
        XCTAssertTrue(["built_in", "wired", "usb", "bluetooth", "continuity", "other", "unknown"].contains(now), now)
    }
    #endif

    func testMicrophonePermissionIsReadable() {
        // reading it never prompts; a CI runner has no microphone and is .denied or .undetermined
        _ = Microphone.permission
    }
}
