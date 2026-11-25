// Wrong keyboard layout (2026-10-31, Andrii: "a quick english to ukrainian switch"): "ghbdsn" typed with ABC on
// means "привіт" on Ukrainian-PC. The key map is read from the two layouts installed on this Mac (UCKeyTranslate),
// so it matches his keyboard exactly. Words are judged by the macOS spellchecker (English and Ukrainian, offline)
// and his own words (engine word list), never by a model.
import AppKit
import Carbon

enum KeyLayout {
    static let ukIDs = ["com.apple.keylayout.Ukrainian-PC", "com.apple.keylayout.Ukrainian"]
    static let enIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British"]

    static func source(_ ids: [String]) -> TISInputSource? {
        for id in ids {
            let props = [kTISPropertyInputSourceID as String: id] as CFDictionary
            if let list = TISCreateInputSourceList(props, true)?.takeRetainedValue() as? [TISInputSource], let s = list.first { return s }
        }
        return nil
    }

    /// keycode -> (plain, shifted) characters of a layout
    static func keys(_ src: TISInputSource) -> [Int: (String, String)] {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var out: [Int: (String, String)] = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func ch(_ code: Int, _ mods: UInt32) -> String {
                var dead: UInt32 = 0, len = 0, chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), (mods >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                return st == noErr ? String(utf16CodeUnits: chars, count: len) : ""
            }
            for code in 0..<51 where ![36, 48, 49].contains(code) {
                out[code] = (ch(code, 0), ch(code, UInt32(shiftKey)))
            }
        }
        return out
    }

    /// ABC character -> Ukrainian character and back, for keys that differ.
    static let maps: (toUk: [Character: Character], toEn: [Character: Character]) = {
        guard let en = source(enIDs), let uk = source(ukIDs) else { return ([:], [:]) }
        let e = keys(en), u = keys(uk)
        var toUk: [Character: Character] = [:], toEn: [Character: Character] = [:]
        for (code, (ep, es)) in e {
            guard let (up, us) = u[code] else { continue }
            for (a, b) in [(ep, up), (es, us)] where a.count == 1 && b.count == 1 && a != b {
                toUk[Character(a)] = Character(b); toEn[Character(b)] = Character(a)
            }
        }
        return (toUk, toEn)
    }()

    static func convert(_ s: String, toUk: Bool) -> String {
        let m = toUk ? maps.toUk : maps.toEn
        return String(s.map { m[$0] ?? $0 })
    }

    static var currentID: String {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    static var ukrainianNow: Bool { ukIDs.contains(currentID) }

    /// The current input source's language ("uk", "en", ...; 2026-11-16, Andrii: "pass the fact of my current language
    /// setting to Claude"): sent as `kb` with requests that can reach Claude (engine/whom.py). Read on the main thread
    /// (TIS); elsewhere the last value read there.
    private static var lastLanguage = ""
    static var language: String {
        guard Thread.isMainThread else { return lastLanguage }
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String], let first = langs.first else { return lastLanguage }
        lastLanguage = first
        return first
    }

    static func select(uk: Bool) {
        if let s = source(uk ? ukIDs : enIDs) { TISSelectInputSource(s) }
    }

    static let cyr = CharacterSet(charactersIn: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ'’")
    static let cyrLetters = CharacterSet(charactersIn: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ")
    static let latin = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The word typed in the wrong layout, fixed: (what to replace, its replacement, the layout it is in), or nil.
    /// `token` is the last run of non-space characters, punctuation included (on ABC "," is "б", "." is "ю").
    static func fix(_ token: String, known: (String) -> Bool) -> (old: String, new: String, toUk: Bool)? {
        guard token.count >= 3, token.count <= 30, !token.contains(where: { $0.isNumber || "@/_#:".contains($0) }) else { return nil }
        let isLatin = token.unicodeScalars.contains { latin.contains($0) }
        let isCyr = token.unicodeScalars.contains { cyrLetters.contains($0) }
        guard isLatin != isCyr else { return nil }
        // try the whole token, then without trailing punctuation that is a real stop
        var tries = [token]
        if let last = token.last, ",.!?;:".contains(last) { tries.append(String(token.dropLast())) }
        for t in tries where t.count >= 3 {
            let tail = String(token.dropFirst(t.count))
            if isLatin {
                let letters = t.filter { $0.isLetter }
                guard letters.count >= 2, !Spell.known(letters, "en"), !known(letters.lowercased()) else { continue }
                let uk = convert(t, toUk: true)
                // a 3-letter word only when it is one of his (nfr -> так); the dictionary alone turns cfg into сап
                guard uk.allSatisfy({ $0.isLetter || "'’ʼ".contains($0) }), uk.count >= 3,
                      known(uk.lowercased()) || (uk.count > 3 && Spell.known(uk, "uk")) else { continue }
                return (t + tail, uk + tail, true)
            } else {
                guard !Spell.known(t, "uk"), !known(t.lowercased()) else { continue }
                let en = convert(t, toUk: false)
                guard en.allSatisfy({ $0.isLetter || $0 == "'" }), en.count >= 3,
                      known(en.lowercased()) || (en.count > 3 && Spell.known(en, "en")) else { continue }
                return (t + tail, en + tail, false)
            }
        }
        return nil
    }
}

/// macOS spellchecker, offline. English and Ukrainian.
enum Spell {
    static let checker = NSSpellChecker.shared
    static func known(_ w: String, _ lang: String) -> Bool {
        let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
    /// Does a word the Mac knows start with these letters? (a word still being typed may be right after all)
    static func starts(_ w: String, _ lang: String) -> Bool {
        let low = w.lowercased()
        let c = checker.completions(forPartialWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: lang, inSpellDocumentWithTag: 0) ?? []
        return c.contains { $0.lowercased().hasPrefix(low) && $0.count > w.count }
    }
    /// macOS's own autocorrection for a word, if it has one.
    static func correction(_ w: String, _ lang: String) -> String? {
        checker.correction(forWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: lang, inSpellDocumentWithTag: 0)
    }
}
