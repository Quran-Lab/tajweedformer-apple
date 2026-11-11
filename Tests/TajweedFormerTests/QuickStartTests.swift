import XCTest

/// The README's quick start is the marked region of the example program (examples/QuickStart), which CI builds; this
/// test keeps the README's text equal to it.
final class QuickStartTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let example = "examples/QuickStart/Sources/QuickStart/QuickStart.swift"

    func region() throws -> String {
        let begin = "// README:" + "begin\n"
        let end = "// README:" + "end\n"
        let source = try String(contentsOf: Self.root.appendingPathComponent(Self.example), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let afterBegin = source.components(separatedBy: begin)
        guard afterBegin.count == 2 else { throw XCTSkip("one begin mark is expected in \(Self.example)") }
        return afterBegin[1].components(separatedBy: end)[0]
    }

    /// The Swift code under "Quick start" in README.md is the example's marked region, character for character.
    func testTheReadmeShowsTheExamplesCode() throws {
        let code = try region()
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let sections = readme.components(separatedBy: "\n## Quick start\n")
        guard sections.count == 2 else { return XCTFail("README.md has no single \"## Quick start\" section") }
        let blocks = sections[1].components(separatedBy: "```swift\n")
        guard blocks.count > 1 else { return XCTFail("the quick start has no swift block") }
        let shown = blocks[1].components(separatedBy: "```")[0]
        XCTAssertEqual(shown, code, "README.md's quick start and \(Self.example) differ")
    }

    /// Client, model, listen, read: ten lines or fewer.
    func testTheQuickStartIsTenLinesOrFewer() throws {
        let lines = try region().components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertLessThanOrEqual(lines.count, 10, "\(lines)")
        let code = lines.joined(separator: "\n")
        for step in ["TajweedClient(key:", "client.model()", "model.listen(", "session.chunks", "chunk.decoded.text"] {
            XCTAssertTrue(code.contains(step), "the quick start lacks \(step)")
        }
        XCTAssertFalse(code.contains("sampleRate"), "no sample rate appears in the quick start")
    }
}
