"""Execute real Swift control flow with inert focus, keys, paste and queue doubles."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AppGuard(unittest.TestCase):
    def test_return_refinement_and_editor_replacement(self):
        source = ''.join((ROOT / 'app' / f).read_text() for f in ('Voice.swift', 'TalkLive.swift', 'TalkRecord.swift', 'TalkFlow.swift'))
        focus = (ROOT / 'app/Focus.swift').read_text()
        replacement = '\n    static func replace(' + focus.split('\n    static func replace(', 1)[1].split('\n    }\n', 1)[0] + '\n    }'
        draft = source.split('    var sendDraft', 1)[1].split('    var sending', 1)[0]
        predicates = source.split('    var canSend:', 1)[1].split('    /// Right Option', 1)[0]
        callback = source.split('VoiceEngine.shared.careful { slow in', 1)[1].split('\n                }\n            }', 1)[0]
        live_draft = source.split('    func liveDraft', 1)[1].split('    /// What the current run should hold', 1)[0]
        talk = ('final class Talk {\n'
                'enum State { case idle, listening }; var state = State.listening\n'
                'var insertMode = VoiceMode.live, sending = false, long = false, samples = 16000, peak: Float = 0.1, started = 1\n'
                'private var sendDraft' + draft + 'var canSend:' + predicates +
                'func draft(_ s: String) { lastDraft = s }\n'
                'var live = true, prevWords: [Substring] = [], still = 0, lastClean = ""\n'
                'var landedWords = 0, steadyWords = 0, steadyText = "", meter = LiveType.Meter(); var now: Double { 0 }\n'
                'func liveStep() {}\n'
                'func liveDraft' + live_draft +
                'func finish(_ s: String, mark: Bool = true) -> String { s }\n'
                'var lastPut: (neutral: String, out: String, ctx: Int)? = nil\n'   # nothing styled: the old chip
                'func render(_ s: String, again c: Int) -> String { s }\n'
                'func offer(_ slow: String, text: String, mine: Int) {' + callback + '}\n}\n')
        with tempfile.TemporaryDirectory(prefix='drafter-voice-pure-') as directory:
            path = Path(directory)
            (path / 'extracted.swift').write_text('import Foundation\nextension Focus {' + replacement + '\n}\n' + talk)
            command = ['swiftc', '-module-cache-path', str(path / 'cache'),
                       str(path / 'extracted.swift'), str(ROOT / 'app/Rules.swift'), str(ROOT / 'app/LiveType.swift'), str(ROOT / 'app/InsertRules.swift'), str(ROOT / 'app/PutCheckRules.swift'),
                       str(ROOT / 'tests/voice_app_guard.swift'), '-o', str(path / 'check')]
            built = subprocess.run(command, capture_output=True, text=True, timeout=300)
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run([str(path / 'check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn('PASS', checked.stdout)


if __name__ == '__main__':
    unittest.main()
