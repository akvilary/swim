import Foundation

final class BackgroundTask<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: T?
    private var _done = false

    func start(_ work: @escaping @Sendable () -> T) {
        lock.lock()
        _result = nil
        _done = false
        lock.unlock()
        Thread { [weak self] in
            let result = work()
            guard let self else { return }
            self.lock.lock()
            self._result = result
            self._done = true
            self.lock.unlock()
        }.start()
    }

    func consume() -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard _done else { return nil }
        let result = _result
        _result = nil
        _done = false
        return result
    }
}
