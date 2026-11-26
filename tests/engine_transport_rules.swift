// swiftc -parse-as-library app/EngineTransportRules.swift tests/engine_transport_rules.swift -o app/build/engine-transport-rules-test && app/build/engine-transport-rules-test
import Foundation

@main
struct EngineTransportRulesChecks {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: " + what); exit(1) }
    }

    static func main() {
        // 1. Single-stream mode (keepOn = false) cancels every existing stream before starting the new one
        check(EngineTransportRules.idsToCancel(active: [], keepOn: false).isEmpty, "empty active cancels nothing")
        check(EngineTransportRules.idsToCancel(active: [(1, false)], keepOn: false) == [1], "single mode cancels active stream")
        check(EngineTransportRules.idsToCancel(active: [(1, true), (2, true)], keepOn: false) == [1, 2], "single mode cancels all active streams")

        // 2. keepOn = true allows predicted + scheduled + kept streams up to maxStreamsKeepOn (4) without evicting
        let three: [(id: Int, keepOn: Bool)] = [(1, true), (2, true), (3, true)]
        check(EngineTransportRules.idsToCancel(active: three, keepOn: true).isEmpty, "3 active streams under keepOn cap 4 evict nothing")

        // At cap (4 active), starting a 5th evicts the newest waiting one; the engine keeps the oldest running
        let fourKeep: [(id: Int, keepOn: Bool)] = [(1, true), (2, true), (3, true), (4, true)]
        check(EngineTransportRules.idsToCancel(active: fourKeep, keepOn: true) == [4], "at cap 4, newest keepOn stream is evicted, oldest kept")

        // Prefer evicting non-keepOn streams before keepOn streams
        let mixed: [(id: Int, keepOn: Bool)] = [(1, true), (2, false), (3, true), (4, true)]
        check(EngineTransportRules.idsToCancel(active: mixed, keepOn: true) == [2], "prefers evicting non-keepOn stream over kept stream")

        // 3. Stale HTTP/1.1 keep-alive retry policy (-1005) — safe read-only / idempotent paths only
        check(EngineTransportRules.shouldRetry(method: "GET", path: "/health", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "retries GET once on -1005 before any bytes arrive")
        check(EngineTransportRules.shouldRetry(method: "POST", path: "/complete", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "retries idempotent POST /complete once on -1005")
        check(!EngineTransportRules.shouldRetry(method: "POST", path: "/act", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "never retries mutating POST /act")
        check(!EngineTransportRules.shouldRetry(method: "POST", path: "/typed", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "never retries mutating POST /typed")
        check(!EngineTransportRules.shouldRetry(method: "POST", path: "/done", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "never retries mutating POST /done")
        check(!EngineTransportRules.shouldRetry(method: "GET", path: "/health", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 1, receivedAnyData: false),
              "never retries a second time")
        check(!EngineTransportRules.shouldRetry(method: "POST", path: "/complete", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: true),
              "never retries mid-stream after partial data already arrived")
        check(!EngineTransportRules.shouldRetry(method: "GET", path: "/health", errorDomain: NSURLErrorDomain, errorCode: NSURLErrorTimedOut, attempt: 0, receivedAnyData: false),
              "does not retry timeouts")
        check(!EngineTransportRules.shouldRetry(method: "GET", path: "/health", errorDomain: NSCocoaErrorDomain, errorCode: NSURLErrorNetworkConnectionLost, attempt: 0, receivedAnyData: false),
              "requires NSURLErrorDomain")

        // 4. Engine token and instance: the API key goes only to the engine this app started
        check(EngineTransportRules.health(ok: true, instance: "abc123", expected: "abc123") == .ours, "matching instance is ours")
        check(EngineTransportRules.health(ok: true, instance: "other", expected: "abc123") == .foreign, "another instance on the port is foreign")
        check(EngineTransportRules.health(ok: true, instance: nil, expected: "abc123") == .foreign, "an engine without an instance is foreign")
        check(EngineTransportRules.health(ok: true, instance: "", expected: "") == .foreign, "no expected instance never counts as ours")
        check(EngineTransportRules.health(ok: true, instance: "abc123", expected: "") == .foreign, "no expected instance: foreign even with one reported")
        check(EngineTransportRules.health(ok: false, instance: "abc123", expected: "abc123") == .notYet, "not ok yet: wait")
        check(EngineTransportRules.health(ok: true, instance: "ABC123", expected: "abc123") == .foreign, "instance match is exact")
        check(EngineTransportRules.busyInfo(port: 8798) == "port 8798 busy, retrying", "busy status names the port")
        check(!EngineTransportRules.sendsToken(path: "/health"), "the token never goes to /health")
        check(EngineTransportRules.sendsToken(path: "/health/x"), "only /health itself is open")
        check(EngineTransportRules.sendsToken(path: "/pending?wait=25"), "the token goes with /pending")
        check(EngineTransportRules.sendsToken(path: "/model-key"), "the token goes with /model-key")
        check(EngineTransportRules.hex([0x00, 0x0f, 0xa0, 0xff]) == "000fa0ff", "hex is lowercase, two digits a byte")
        check(EngineTransportRules.hex([UInt8](repeating: 7, count: 32)).count == 64, "32 bytes make 64 hex digits")
        check(EngineTransportRules.tokenHeader == "X-Drafter-Token", "header name matches engine/server.py")

        print("engine transport rules: all checks passed")
    }
}
