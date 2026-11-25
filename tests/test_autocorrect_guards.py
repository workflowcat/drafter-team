"""Compile the real check() with in-memory words and a fake speller, never the app."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Guards(unittest.TestCase):
    def test_snapshot_merges_once_and_keep_writes_are_serial(self):
        source = (ROOT/'app/Autocorrect.swift').read_text()
        state = source[source.index('    private static var mine'):source.index('    static let russian')]
        keep = source[source.index('    static func keepWord('):source.index('    /// Double Shift')]
        # Count real merge/write branches without replacing their implementation.
        state = state.replace('loadedSnapshot = snapshot.id', 'loadedSnapshot = snapshot.id; merges += 1')
        keep = keep.replace('if let data = try? JSONEncoder()', 'precondition(!Thread.isMainThread); writes += 1\n            if let data = try? JSONEncoder()')
        swift = '''import Foundation
        enum Home { static var data = URL(fileURLWithPath: CommandLine.arguments[1]) }
        enum Autocorrect {
            static var merges = 0, writes = 0
        ''' + state + keep + '''
            static func test() throws {
                let file = Home.data.appendingPathComponent("autocorrect-keep.json")
                try Data(#"{"legacy":1}"#.utf8).write(to: file, options: .atomic)
                func waitFor(_ condition: () -> Bool) {
                    let until = Date().addingTimeInterval(4)
                    while Date() < until {
                        refresh()
                        if condition() { return }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    preconditionFailure("snapshot not ready")
                }
                waitFor { loadedSnapshot != nil }
                precondition(merges == 1 && counts["legacy"] == 1)
                for _ in 0..<1000 { precondition(refresh()); _ = known("legacy"); _ = nameStarts("Ha") }
                precondition(merges == 1)
                Thread.sleep(forTimeInterval: 1.05); refresh(); Thread.sleep(forTimeInterval: 0.1); refresh()
                precondition(merges == 1)
                let first = loadedSnapshot
                try Data(#"{"legacy":2}"#.utf8).write(to: file, options: .atomic)
                files.invalidate()
                waitFor { loadedSnapshot != first }
                precondition(merges == 2 && known("legacy"))
                try Data("broken".utf8).write(to: file, options: .atomic)
                files.invalidate(); refresh(); Thread.sleep(forTimeInterval: 0.1); refresh()
                precondition(merges == 2 && known("legacy"))
                try Data(#"{"legacy":2}"#.utf8).write(to: file, options: .atomic)

                let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                countWriter.async { blocked.signal(); release.wait() }
                blocked.wait()
                keepWord("tomorow ")
                precondition(counts["tomorow"] == 1 && !known("tomorow"))
                keepWord("tomorow ")
                precondition(counts["tomorow"] == 2 && known("tomorow"))
                precondition(readCounts("autocorrect-keep.json")["tomorow"] == nil)
                release.signal(); countWriter.sync {}
                precondition(writes == 2)
                precondition(readCounts("autocorrect-keep.json") == ["legacy":2, "tomorow":2])
                // An older queued disk snapshot never removes in-memory protection.
                files.publish(Snapshot(mine: [], names: [], counts: ["tomorow":1], index: CorrectionRules.Index([:])))
                refresh(); precondition(counts["tomorow"] == 2 && known("tomorow"))
                print("PASS: snapshot merge identity, immediate protection and serial background writes")
            }
        }
        @main struct Checks { static func main() throws { try Autocorrect.test() } }
        '''
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); fixture = root/'snapshot.swift'; fixture.write_text(swift)
            built = subprocess.run(['swiftc', '-module-cache-path', str(root/'cache'),
                                    str(ROOT/'app/CorrectionRules.swift'), str(ROOT/'app/LocalSnapshot.swift'),
                                    str(fixture), '-o', str(root/'check')], capture_output=True, text=True, timeout=300)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(root/'check'), str(root)], capture_output=True, text=True, timeout=60)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn('PASS:', ran.stdout)

    def test_own_candidates_cannot_bypass_live_guards(self):
        source = (ROOT/'app/Autocorrect.swift').read_text()
        check = source[source.index('    static func check('):source.index('    /// Replace the word')]
        swift = '''import Foundation
        enum KeyLayout {
            static let cyr = CharacterSet(charactersIn: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя")
            static func fix(_ word: String, known: (String) -> Bool) -> (old: String, new: String, toUk: Bool)? { nil }
        }
        enum Spell {
            static var words = Set<String>()
            static func known(_ word: String, _ lang: String) -> Bool { words.contains(word) }
            static func correction(_ word: String, _ lang: String) -> String? { nil }
        }
        enum TypoEngine {
            static var calls = 0
            static func check(_ token: String, line: String, app: String, kind: String, typosUk: Bool) -> (old: String, new: String, kind: String)? {
                calls += 1; return (token + " ", "ranked ", "typo")
            }
        }
        enum Autocorrect {
            static var ready = true, restored = "", protected = Set<String>()
            static var ownIndex = CorrectionRules.Index(["tomorrow":20, "don't":10, "поговорити":10, "map":100, "the":100])
            static let russian = CharacterSet(charactersIn: "ыэъёЫЭЪЁ")
            static func refresh() -> Bool { ready }
            static func known(_ word: String) -> Bool { protected.contains(word) }
            static func distance(_ a: String, _ b: String) -> Int { CorrectionRules.distance(a, b) }
        ''' + check + '''}
        @main struct Checks {
            static func main() {
                func fix(_ word: String, uk: Bool = false) -> String? {
                    Autocorrect.check(word + " ", layout: false, typos: true, typosUk: uk)?.new
                }
                precondition(fix("tomorow") == "tomorrow ")
                Spell.words = ["tomorow"]; precondition(fix("tomorow") == nil); Spell.words = []
                Autocorrect.protected = ["tomorow"]; precondition(fix("tomorow") == nil); Autocorrect.protected = []
                Autocorrect.ready = false; precondition(fix("tomorow") == nil); Autocorrect.ready = true
                precondition(Autocorrect.check("tomorow ", layout:false, typos:false) == nil)
                precondition(fix("Tomorow") == nil)
                precondition(fix("dont") == "don't ")
                precondition(fix("tmp") == nil && fix("mvp") == nil)
                precondition(fix("поговорти") == nil)
                precondition(fix("поговорти", uk:true) == "поговорити ")
                precondition(fix("поговрти", uk:true) == nil)
                Autocorrect.restored = "tomorow"; precondition(fix("tomorow") == nil)
                precondition(fix("tomorow") == "tomorrow ")
                // the ranked engine takes over only when asked, after the layout fix and the typos switch
                precondition(Autocorrect.check("tomorow ", layout: false, typos: true, ranked: true)?.new == "ranked " && TypoEngine.calls == 1)
                precondition(Autocorrect.check("tomorow ", layout: false, typos: false, ranked: true) == nil && TypoEngine.calls == 1)
                print("PASS: live correction eligibility with fake speller and in-memory words")
            }
        }
        '''
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); fixture = root/'check.swift'; fixture.write_text(swift)
            built = subprocess.run(['swiftc', '-module-cache-path', str(root/'cache'), str(ROOT/'app/CorrectionRules.swift'), str(fixture), '-o', str(root/'check')], capture_output=True, text=True, timeout=300)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(root/'check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn('PASS:', ran.stdout)

if __name__ == '__main__': unittest.main()
