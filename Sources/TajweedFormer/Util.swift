import Foundation

/// Runs blocking work (hashing, model loading) off the caller's executor, keeping the typed error.
func detached<T: Sendable>(_ body: @escaping @Sendable () throws(RecognizerError) -> T) async throws(RecognizerError) -> T {
    try await Task.detached(priority: .userInitiated) { () -> Result<T, RecognizerError> in
        do throws(RecognizerError) {
            return .success(try body())
        } catch {
            return .failure(error)
        }
    }.value.get()
}

/// A value behind a lock, for the little process-wide state the SDK has.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R, E: Error>(_ body: (inout Value) throws(E) -> R) throws(E) -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
