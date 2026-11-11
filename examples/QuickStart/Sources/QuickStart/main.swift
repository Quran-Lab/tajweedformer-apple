import Foundation
import TajweedFormer

// Run with QURANLAB_KEY set. Without arguments: a sample clip through the same path as the microphone, so it works
// in CI, in a simulator and on a Mac without an input. With --listen: takes on the microphone, one after another.
// With --quickstart: the README's quick start as it is.

/// A take from one of the model's sample clips, without a microphone: the same Session, chunks and events.
func runSampleClip(_ model: TajweedModel) async throws {
    guard let clip = model.sampleClips.first else { return print("this model has no sample clips") }
    let session = try await model.listen(from: clip, options: .init(pace: .fast))
    for await chunk in session.chunks where chunk.decoded.isFinal {
        print("\(clip.name) (\(clip.durationMs) ms): \(chunk.decoded.text)")
    }
    let heads = try await session.finish()                     // the take's raw heads
    print("heads: \(heads.names.joined(separator: ", "))")
}

/// Takes one after another on the microphone. A take ends by itself after 1.5 s of silence, and when the app leaves
/// the foreground (`ended(.background)` on iOS); the next take is one line.
func listenInTakes(_ model: TajweedModel) async throws {
    while true {
        let session = try await model.listen(options: .init(endOnSilenceMs: 1500))   // a new take: also after a return from the background
        for await event in session.events {
            if case .speechStarted = event { print("...") }
            if case .ended(let reason) = event { print("take ended: \(reason)") }
        }
        let heads = try await session.finish()
        print(heads.decoded().text)
    }
}

let key = ProcessInfo.processInfo.environment["QURANLAB_KEY"] ?? ""
do {
    if CommandLine.arguments.contains("--quickstart") {
        try await quickStart(key: key)
    } else {
        let client = try TajweedClient(key: key)
        let model = try await client.model()
        let backend = await model.backend
        print("model \(model.id) \(model.version), contexts \(model.contexts), backend \(backend)")
        if CommandLine.arguments.contains("--listen") { try await listenInTakes(model) } else { try await runSampleClip(model) }
        client.close()
    }
} catch let error as TajweedError {
    print("\(error.code): \(error.message)\n\(error.fix)\n\(error.docs)")
    exit(1)
}
