// Pure HTTP transport rules for Engine.swift: stream concurrency cap (preserving keep_on streams during
// predicted+scheduled keystroke bursts), single-retry policy when an idle HTTP/1.1 keep-alive socket closes (-1005), and
// the engine token and instance check that keeps an API key away from any other process on the port.
import Foundation

enum EngineTransportRules {
    /// Maximum concurrent /complete streams allowed before cancelling older ones.
    /// When `keepOn` is true, predicted + scheduled + kept-in-flight streams can coexist cleanly without aborting the kept stream.
    static let maxStreamsKeepOn = 4
    static let maxStreamsSingle = 1

    /// Returns the IDs of active streams to cancel before starting a new stream with `keepOn`.
    static func idsToCancel(active: [(id: Int, keepOn: Bool)], keepOn: Bool) -> [Int] {
        let cap = keepOn ? maxStreamsKeepOn : maxStreamsSingle
        let overflow = active.count - (cap - 1)
        guard overflow > 0 else { return [] }
        if !keepOn {
            return active.prefix(overflow).map(\.id)
        }
        // Cancel older non-keepOn streams first, then the newest waiting keepOn ones:
        // the engine keeps the oldest one running, so dropping it would waste the work already done.
        var victims: [Int] = []
        for item in active where !item.keepOn && victims.count < overflow {
            victims.append(item.id)
        }
        for item in active.reversed() where item.keepOn && victims.count < overflow {
            victims.append(item.id)
        }
        return victims
    }

    /// Safe read-only / idempotent POST endpoints where retrying once on -1005 cannot cause duplicate side effects.
    static let retryablePostPaths: Set<String> = [
        "/complete", "/prefill", "/chip", "/futures"
    ]

    /// True if `method` + `path` is safe to retry once on -1005 (all GETs, plus read-only/idempotent POSTs).
    static func isSafeToRetry(method: String, path: String) -> Bool {
        if method.uppercased() == "GET" { return true }
        let base = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return retryablePostPaths.contains(base)
    }

    /// Retry once when an idle HTTP/1.1 keep-alive connection was closed by the server before any response bytes arrived.
    static func shouldRetry(method: String = "GET", path: String = "/health",
                            errorDomain: String, errorCode: Int, attempt: Int, receivedAnyData: Bool) -> Bool {
        attempt == 0
            && !receivedAnyData
            && isSafeToRetry(method: method, path: path)
            && errorDomain == NSURLErrorDomain
            && errorCode == NSURLErrorNetworkConnectionLost
    }

    // MARK: engine token and instance (2026-11-26)

    /// The header every engine route but GET /health needs.
    static let tokenHeader = "X-Drafter-Token"

    /// GET /health is the one open route; the token is never sent there, so whatever holds the port learns nothing.
    static func sendsToken(path: String) -> Bool {
        (path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path) != "/health"
    }

    /// Lowercase hex of random bytes (the token, the instance id).
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// What one /health answer means. `ours` only when the engine there reports the instance id this app gave the
    /// process it started; anything else holding the port is `foreign` and never gets an API key.
    enum Health: Equatable { case ours, foreign, notYet }

    static func health(ok: Bool, instance: String?, expected: String) -> Health {
        guard ok else { return .notYet }
        guard !expected.isEmpty, let instance, instance == expected else { return .foreign }
        return .ours
    }

    /// The status line while another process holds the engine's port.
    static func busyInfo(port: Int) -> String { "port \(port) busy, retrying" }
}
