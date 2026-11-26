// swiftc -parse-as-library app/EntityRules.swift app/RefRules.swift tests/picker_key_guards.swift -o app/build/picker-key-guards-test && app/build/picker-key-guards-test
// The pickers' list keys (PickerKeys): a key with ⌘⌃⌥⇧ held is never taken as a plain ↑↓ ←→ or ↵, on both keycodes of
// each pair. Before 26 November 2026 `case 125, 126 where plain` guarded ↑ only, so ⌘↓ moved the list.
import Foundation

@main
enum PickerKeyGuardsTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }

    // the picker's `plain`: only ⌘⌃⌥⇧ reach it (Keys.swift masks the rest); these are those flags' raw bits
    static let cmd: UInt64 = 0x100000, shift: UInt64 = 0x20000, opt: UInt64 = 0x80000, ctrl: UInt64 = 0x40000
    static func plain(_ mods: UInt64) -> Bool { mods == 0 }

    static func main() {
        let held: [(String, UInt64)] = [("⌘", cmd), ("⇧", shift), ("⌥", opt), ("⌃", ctrl), ("⌘⇧", cmd | shift)]
        for (name, m) in held {
            for code: Int64 in [36, 76] { check(!PickerKeys.enter(code, on: plain(m)), "\(name)↵ (\(code)) is not the picker's") }
            for code: Int64 in [125, 126] { check(PickerKeys.step(code, on: plain(m)) == nil, "\(name) arrow \(code) is not a step") }
            for code: Int64 in [123, 124] { check(PickerKeys.side(code, on: plain(m)) == nil, "\(name) arrow \(code) is not a side step") }
        }
        // plain keys work on both codes of each pair
        check(PickerKeys.enter(36, on: plain(0)) && PickerKeys.enter(76, on: plain(0)), "plain ↵ and keypad enter pick")
        check(PickerKeys.step(125, on: true) == 1 && PickerKeys.step(126, on: true) == -1, "↓ +1, ↑ -1")
        check(PickerKeys.side(124, on: true) == 1 && PickerKeys.side(123, on: true) == -1, "→ +1, ← -1")
        // other keys are never these
        for code: Int64 in [0, 48, 51, 53, 8] {
            check(!PickerKeys.enter(code, on: true) && PickerKeys.step(code, on: true) == nil && PickerKeys.side(code, on: true) == nil, "key \(code) is none")
        }
        check(PickerKeys.step(123, on: true) == nil && PickerKeys.side(125, on: true) == nil, "the pairs do not cross")
        // the context tray's own condition (not .tray or no row): ← no longer reaches tray[sel] (an empty tray crashed)
        check(PickerKeys.side(123, on: false) == nil && PickerKeys.side(124, on: false) == nil, "← and → both need the tray row")
        if failed > 0 { print("picker key guards: \(failed) failed"); exit(1) }
        print("picker key guards: all checks passed")
    }
}
