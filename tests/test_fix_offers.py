"""Fix offers round (13 November 2026): app kinds, the take-back keep rule, the new settings and the
keep-list audit. Compiles only pure pieces of the app with synthetic words; never the app, never data/."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'bench'))
import keep_audit  # noqa: E402


def run_swift(test, files, program, marker):
    with tempfile.TemporaryDirectory(prefix='drafter-fix-test-') as folder:
        path = Path(folder)
        (path / 'main.swift').write_text(program)
        built = subprocess.run(['swiftc', '-module-cache-path', str(path / 'cache'), *map(str, files), str(path / 'main.swift'),
                                '-o', str(path / 'check')], capture_output=True, text=True, timeout=300)
        test.assertEqual(built.returncode, 0, built.stderr)
        ran = subprocess.run([str(path / 'check'), str(path)], capture_output=True, text=True, timeout=60)
        test.assertEqual(ran.returncode, 0, ran.stderr)
        test.assertIn(marker, ran.stdout)


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class Swift(unittest.TestCase):
    def test_app_kinds(self):
        program = r'''import Foundation
let ai = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.perplexity.mac"]
let chats = ["com.automattic.beeper.desktop", "com.tinyspeck.slackmacgap"]
let browsers = ["com.google.Chrome", "company.thebrowser.dia"]
let aiTitle = try! NSRegularExpression(pattern: #"(?i)\b(chatgpt|claude|gemini|perplexity|grok)\b"#)
func kind(_ id: String, _ title: String = "") -> String { AppKind.of(id, title: title, ai: ai, chats: chats, browsers: browsers, aiTitle: aiTitle) }
precondition(kind("com.anthropic.claudefordesktop") == "ai")
precondition(kind("com.openai.codex") == "ai")
precondition(kind("com.automattic.beeper.desktop") == "chat")
precondition(kind("com.apple.mail") == "mail")
precondition(kind("com.google.Chrome", "Claude - New chat") == "ai")
precondition(kind("company.thebrowser.dia", "Inbox (3) - Gmail") == "mail")
precondition(kind("com.google.Chrome", "Docs") == "other")
precondition(kind("com.apple.TextEdit", "Claude notes") == "other")   // a title counts only in a browser
precondition(AppKind.kinds.contains("ai"))
print("PASS app kinds")
'''
        run_swift(self, [ROOT / 'app/AppKind.swift'], program, 'PASS app kinds')

    def test_take_back_counts_only_a_word_left_standing(self):
        source = (ROOT / 'app/Autocorrect.swift').read_text()
        stands = source[source.index('    static func stands('):source.index('    /// His word, put back')]
        program = 'import Foundation\nenum Autocorrect {\n' + stands + r'''}
precondition(Autocorrect.stands("wrod", in: "so the wrod"))
precondition(Autocorrect.stands("wrod", in: "so the wrod is, and more "))
precondition(Autocorrect.stands("wrod", in: "so the wrod,\u{A0}"))
precondition(!Autocorrect.stands("wrod", in: "so the wr"))          // he went on deleting into it
precondition(!Autocorrect.stands("wrod", in: "so the word"))        // and fixed it by hand
precondition(!Autocorrect.stands("", in: "anything"))
print("PASS stands")
'''
        run_swift(self, [], program, 'PASS stands')


class KeepAudit(unittest.TestCase):
    def test_flags_typos_of_his_words_only(self):
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder)
            (data / 'autocorrect-keep.json').write_text(json.dumps({'tomorow': 2, 'teh': 1, 'datakit': 2, 'zzzz': 1}))
            (data / 'autocorrect-keep.txt').write_text('recieve\n')
            (data / 'myword-counts.json').write_text(json.dumps({'tomorrow': 80, 'the': 900, 'receive': 12, 'datakit': 40, 'datakits': 6}))
            (data / 'mywords.txt').write_text('tomorrow\nthe\nreceive\ndatakit\ndatakits\n')
            counts, used, mine = keep_audit.load(data)
            rows = {r[0]: r for r in keep_audit.audit(counts, used, mine)}
            self.assertEqual(set(rows), {'tomorow', 'teh', 'recieve', 'datakit'})
            self.assertTrue(rows['tomorow'][5] and rows['teh'][5] and rows['recieve'][5])
            self.assertEqual(rows['teh'][3], 'the')                       # a swap counts as one edit
            self.assertFalse(rows['datakit'][5])                          # his own word, written more than its neighbour
            self.assertEqual(rows['recieve'][1], 1)                        # the legacy list counts as one take-back
            self.assertEqual(keep_audit.main(['--data', str(data), '--summary']), 0)


if __name__ == '__main__':
    unittest.main()
