import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5: the sharing resampler gives the input's whole length at 48 kHz on every platform. iOS's converter ended
/// its stream without the filter's tail when it upsamples by about 2 or more (4 s at 16 kHz came out 699 samples short,
/// 22.05 kHz 229, 24 kHz 126, 8 kHz 2424, on the iPhone and the Simulator; macOS was whole). Each case feeds a tone in
/// pieces as a microphone gives them, flushes, and checks the length and that the end is the tone, not silence.
final class ShareResamplerTests: XCTestCase {
    static func tone(_ n: Int, rate: Double) -> [Float] { (0..<n).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) } }

    /// The resampler's whole output for `n` samples at `rate`, fed in pieces of 10 to 40 ms.
    static func resample(_ n: Int, rate: Double) throws -> [Float] {
        let x = tone(n, rate: rate)
        let rs = try ShareResampler(inputRate: rate)
        var y: [Float] = []
        var at = 0, k = 0
        while at < n {
            let m = min(max(1, Int(rate / 100)) * (1 + k % 4), n - at)
            try x[at..<(at + m)].withUnsafeBufferPointer { b in try rs.process(b) { y.append(contentsOf: $0) } }
            at += m
            k += 1
        }
        try rs.flush { y.append(contentsOf: $0) }
        return y
    }

    /// The relative error of `y` against the 48 kHz tone over `count` samples from `from`.
    static func error(_ y: [Float], from: Int, count: Int) -> Double {
        var e = 0.0, s = 0.0
        for i in from..<(from + count) {
            let r = 0.5 * sin(2 * Double.pi * 440 * Double(i) / 48_000)
            e += abs(Double(y[i]) - r)
            s += abs(r)
        }
        return e / max(s, 1e-9)
    }

    func check(_ rate: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let y = try Self.resample(Int(rate * 4), rate: rate)
        XCTAssertEqual(y.count, 192_000, "4 s at \(rate) Hz is 4 s at 48 kHz", file: file, line: line)
        guard y.count > 10_000 else { return }
        // the tone through to its end (the last 100 ms before the filter's own edge), not silence put in its place
        XCTAssertLessThan(Self.error(y, from: y.count - 4_800 - 1_000, count: 4_800), 0.01, "\(rate) Hz: the end is the tone", file: file, line: line)
        XCTAssertLessThan(Self.error(y, from: 4_800, count: 4_800), 0.01, "\(rate) Hz: aligned at the start", file: file, line: line)
    }

    func test16kHzIsWhole() throws { try check(16_000) }

    func test22050HzIsWhole() throws { try check(22_050) }

    func test24kHzIsWhole() throws { try check(24_000) }

    func testTheOtherRatesAreWhole() throws {
        for rate in [8_000.0, 11_025.0, 32_000.0, 44_100.0, 48_000.0, 96_000.0] { try check(rate) }
    }

    /// A length that is not whole at 48 kHz: rounded down when upsampling (as macOS's converter gives it).
    func testAPartLengthIsRoundedDown() throws {
        for (rate, n) in [(16_000.0, 1_234), (22_050.0, 74_308), (11_025.0, 1_234), (24_000.0, 37), (8_000.0, 26_960)] {
            let y = try Self.resample(n, rate: rate)
            XCTAssertEqual(y.count, Int((Double(n) * 48_000 / rate).rounded(.down)), "\(n) at \(rate) Hz")
        }
    }
}
