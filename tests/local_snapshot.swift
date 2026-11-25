import Foundation
// swiftc -parse-as-library app/LocalSnapshot.swift tests/local_snapshot.swift -o app/build/local_snapshot-test && app/build/local_snapshot-test
@main struct Checks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fixture.json")
        try Data("{\"value\":1}".utf8).write(to: path, options: .atomic)
        let countLock = NSLock(); var decodes = 0
        let cache = LocalSnapshot<[String: Int]>([path]) { files in
            precondition(!Thread.isMainThread)
            countLock.lock(); decodes += 1; countLock.unlock()
            guard let data = files[0] else { return [:] }
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        func waitFor(_ expected: [String: Int]) {
            let until = Date().addingTimeInterval(3)
            while Date() < until { if cache.read() == expected { return }; Thread.sleep(forTimeInterval: 0.01) }
            preconditionFailure("snapshot not published")
        }
        precondition(cache.read() == nil)
        waitFor(["value":1])
        for _ in 0..<1000 { precondition(cache.read() == ["value":1]) }
        Thread.sleep(forTimeInterval: 1.05); _ = cache.read(); Thread.sleep(forTimeInterval: 0.1)
        countLock.lock(); precondition(decodes == 1); countLock.unlock()
        try Data("{\"value\":2}".utf8).write(to: path, options: .atomic)
        waitFor(["value":2])
        try Data("invalid".utf8).write(to: path, options: .atomic)
        Thread.sleep(forTimeInterval: 1.05); _ = cache.read(); Thread.sleep(forTimeInterval: 0.1)
        precondition(cache.read() == ["value":2])
        cache.publish(["value":3]); precondition(cache.read() == ["value":3])
        try FileManager.default.removeItem(at: path)
        waitFor([:])
        print("PASS: background snapshots, unchanged mtime, reload, malformed retention, publish and deletion")
    }
}
