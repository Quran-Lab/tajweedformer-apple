import Foundation

extension Array where Element == Float {
    /// `withUnsafeBufferPointer` for a body that throws `RecognizerError`, with that failure carried out of the closure:
    /// Swift 6.0 (Xcode 16.0 to 16.2, the README's oldest toolchain) rethrows a typed throw from inside
    /// `withUnsafeBufferPointer` as `any Error`, which a `throws(RecognizerError)` caller cannot throw.
    func withBuffer<R>(_ body: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> R) throws(RecognizerError) -> R {
        let result: Result<R, RecognizerError> = withUnsafeBufferPointer { p in
            do throws(RecognizerError) {
                return .success(try body(p))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}
