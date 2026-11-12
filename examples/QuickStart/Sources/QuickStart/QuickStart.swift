// The README's quick start: Client, model, listen, read. CI compiles this file, and a test keeps the README's text
// equal to the marked region.
// README:begin
import TajweedFormer

func quickStart(key: String) async throws {
    let client = try TajweedClient(key: key)                  // once per process; your key from sdk.quranlab.ai
    let model = try await client.model()                      // downloads the model once, verifies it, opens and warms it
    let session = try await model.listen(options: .init(endOnSilenceMs: 1500))   // asks for the microphone
    for await chunk in session.chunks {                       // every 320 ms, until 1.5 s of silence end the take
        print(chunk.decoded.text)                             // what the model heard so far
    }
}
// README:end
