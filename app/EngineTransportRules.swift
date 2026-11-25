// Pure HTTP transport rules for Engine.swift: stream concurrency cap (preserving keep_on streams during
// predicted+scheduled keystroke bursts) and single-retry policy when an idle HTTP/1.1 keep-alive socket closes (-1005).
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
        "/complete", "/prefill", "/chip", "/futures", "/lookup"
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
}
