import Foundation

/// For measurements on a device (tests reach it with `@testable import`): the sharing writer
/// exactly as a shared session uses it (resampler, libopus, one-second pages, the segment plan),
/// writing into `folder` with no outbox and no network. Not part of the public API.
final class SharingProbe {
    struct Segment: Sendable, Codable {
        let name: String
        let bytes: Int
        let granule: Int64
    }

    private let writer: OggOpusWriter
    private var segments: [Segment] = []
    /// CPU seconds spent in `append` and `finish` (thread time).
    private(set) var cpuSeconds = 0.0

    init(folder: URL, inputRate: Double) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = Box()
        writer = try OggOpusWriter(segmentURL: { folder.appendingPathComponent(ShareFiles.name($0)).appendingPathExtension("opus") },
                                   plan: SegmentPlan.seconds, inputRate: inputRate) { box.closed.append($0) }
        self.box = box
    }

    private final class Box { var closed: [OggSegment] = [] }
    private let box: Box

    var preSkip: Int { writer.preSkip }

    func append(_ samples: [Float]) throws {
        let t = Self.threadCPU()
        try writer.append(samples)
        cpuSeconds += Self.threadCPU() - t
    }

    /// Ends the stream; returns every segment's size and last granule position.
    func finish() throws -> [Segment] {
        let t = Self.threadCPU()
        try writer.finish()
        cpuSeconds += Self.threadCPU() - t
        return box.closed.map { s in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: s.url.path)[.size] as? Int) ?? 0
            return Segment(name: s.url.lastPathComponent, bytes: bytes, granule: s.granule)
        }
    }

    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}
