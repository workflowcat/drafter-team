// File metadata, decoding and index building run on a utility queue, never the event tap.
// Readers use the last complete snapshot. A cold reader returns nil and stays quiet.
import Foundation

final class LocalSnapshot<Value> {
    private let paths: [URL], decode: ([Data?]) throws -> Value
    private let queue = DispatchQueue(label: "drafter.local-snapshot", qos: .utility)
    private let lock = NSLock()
    private var value: Value?, stamps: [String]?, busy = false, next = Date.distantPast
    private var generation = 0
    init(_ paths: [URL], decode: @escaping ([Data?]) throws -> Value) {
        self.paths = paths; self.decode = decode
    }
    func read() -> Value? {
        lock.lock()
        let result = value
        if !busy && Date() >= next {
            busy = true; next = Date().addingTimeInterval(1)
            let revision = generation, previous = stamps
            queue.async {
                let fresh = self.paths.map { url -> String in
                    guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
                    return "\(a[.modificationDate] ?? "")/\(a[.size] ?? "")/\(a[.systemFileNumber] ?? "")"
                }
                var decoded: Value?
                if fresh != previous { decoded = try? self.decode(self.paths.map { try? Data(contentsOf: $0) }) }
                self.lock.lock()
                if revision == self.generation, let decoded { self.value = decoded; self.stamps = fresh }
                self.busy = false
                self.lock.unlock()
            }
        }
        lock.unlock()
        return result
    }
    func publish(_ updated: Value) {
        lock.lock(); generation += 1; value = updated; stamps = nil; next = .distantPast; lock.unlock()
    }
    func invalidate() {
        lock.lock(); generation += 1; stamps = nil; next = .distantPast; lock.unlock()
    }
}
