import XCTest

// The README's quick start. It lives in the test target so that every CI run type-checks it against the package
// as it is, and the test below keeps the README's text equal to it. It is not run here: it needs a developer
// key, the network and a microphone.
// README:begin
import TajweedFormer

/// The microphone in, what the model heard out.
@MainActor
final class Listener {
    private let microphone = Microphone()
    private var recognizer: TajweedRecognizer?

    func start() async throws {
        QuranLab.configure(key: "qlk_v1_...")                        // once, at launch: your key from portal.quranlab.ai
        guard await Microphone.requestPermission() else { return }   // the system's microphone dialog
        let model = try await TajweedModel.load()                    // downloads the model once, verified
        let recognizer = try TajweedRecognizer(model: model)
        self.recognizer = recognizer
        try await recognizer.startTake()
        let chunks = await recognizer.chunks()
        try microphone.start(into: recognizer)
        for await chunk in chunks {                                  // every 320 ms while the learner recites
            let heard = await recognizer.decoded()                   // what the model heard so far
            print(chunk.index, heard.transcript)
        }
    }

    func stop() async throws {
        microphone.stop()
        try await recognizer?.finish()                               // ends the take, and the loop in start()
    }
}
// README:end

final class QuickStartTests: XCTestCase {
    /// The Swift code under "Quick start" in README.md is the code above, character for character.
    func testTheReadmeShowsThisCode() throws {
        let begin = "// README:" + "begin\n"
        let end = "// README:" + "end\n"
        let file = URL(fileURLWithPath: #filePath)
        let source = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let afterBegin = source.components(separatedBy: begin)
        guard afterBegin.count == 2 else { return XCTFail("one begin mark is expected in \(file.lastPathComponent)") }
        let code = afterBegin[1].components(separatedBy: end)[0]

        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let sections = readme.components(separatedBy: "\n## Quick start\n")
        guard sections.count == 2 else { return XCTFail("README.md has no single \"## Quick start\" section") }
        let blocks = sections[1].components(separatedBy: "```swift\n")
        guard blocks.count > 1 else { return XCTFail("the quick start has no swift block") }
        let shown = blocks[1].components(separatedBy: "```")[0]
        XCTAssertEqual(shown, code, "README.md's quick start and Tests/TajweedFormerTests/QuickStartTests.swift differ")
    }
}
