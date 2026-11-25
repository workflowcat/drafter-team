"""Call recording without audio hardware: the real SysAudio/Tape/Spool code from app/Call.swift, compiled with stand-ins.

3 November 2026: while the main thread hung, the call files stopped growing, mic chunks waited as main-queue blocks,
and the take's end dropped them and the whole other side kept in memory. Now the microphone's queue writes both sides
to disk itself, and a recording closed but never read is read again on the next start.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

STUBS = r'''
import AppKit
enum Home { static var data = URL(fileURLWithPath: CommandLine.arguments[1]) }
var logged: [String] = []
let logLock = NSLock()
func log(_ s: String, file: String = "app.log") { logLock.lock(); logged.append(s); logLock.unlock() }
enum CallWatch { static var event: [String: Any]? }
enum Meeting { static func now(_ at: Date = Date(), needPeople: Bool = false) -> [String: Any]? { nil } }
enum MeetingNotes { static var pending: (event: [String: Any]?, inPerson: Bool)?; static var active = false }
final class Pill { static let shared = Pill(); func flash(_ s: String) {} }
final class Talk {
    static let shared = Talk()
    var read: [String] = []
    func transcribe(dir: URL, me: URL, them: URL?, call: Bool, live: String) { read.append(dir.lastPathComponent) }
}
'''

MAIN = r'''
import Foundation
@main
struct TapeChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static func size(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }

    static func main() {
        try? FileManager.default.createDirectory(at: Spool.root, withIntermediateDirectories: true)
        guard let sp = Spool(call: true, app: "Test") else { print("FAIL: no spool"); exit(1) }
        let tape = Tape()
        tape.attach(sp, call: true)
        let micQ = DispatchQueue(label: "mic")
        let chunk = [Float](repeating: 0.25, count: 1600)   // 0.1 s
        // the main thread is blocked the whole time the microphone delivers: the files must grow anyway
        let wrote = DispatchSemaphore(value: 0)
        var others: [[Float]?] = []
        micQ.async {
            for _ in 0..<50 { others.append(tape.write(chunk, peak: 0.25)) }
            wrote.signal()
        }
        check(wrote.wait(timeout: .now() + 5) == .success, "the microphone's queue writes without the main thread")
        let me = sp.dir.appendingPathComponent("me.pcm"), them = sp.dir.appendingPathComponent("them.pcm")
        check(size(me) == 50 * 1600 * 2, "me.pcm holds every chunk while main is blocked (\(size(me)))")
        check(size(them) == size(me), "a call's other side keeps the same timeline (silence while the Mac's sound is missing)")
        check(others.allSatisfy { $0 == nil }, "no other side for the live mix before call audio runs")
        check(sp.frames == 50 * 1600, "frames count what reached the disk")
        let st = tape.now()
        check(st.meSamples == 50 * 1600 && st.mePeak == 0.25 && st.call, "the strip's numbers come from the queue")
        check(st.sysState == .failed, "a call without call audio says so")
        // the end: detach, then close; a chunk that comes late is never written to a closed file
        guard let closing = tape.detach() else { print("FAIL: detach"); exit(1) }
        check(tape.write(chunk, peak: 0.2) == nil, "after the end the tape writes nothing")
        let (meWav, themWav) = closing.close()
        closing.add(me: chunk, them: chunk)   // a late add after close: no crash, nothing written
        check(FileManager.default.fileExists(atPath: meWav.path), "me.wav written")
        check(size(meWav) == 44 + 50 * 1600 * 2, "me.wav holds all of it")
        check(themWav == nil, "a silent other side is not kept")
        let mark = sp.dir.appendingPathComponent(Unread.marker)
        check(FileManager.default.fileExists(atPath: mark.path), "a closed recording is marked unread until its transcript")
        // a restart: the marked folder is read again; one closed in this run is not
        Spool.recover()
        check(Talk.shared.read.isEmpty, "a recording closed in this run is never taken for a leftover")
        Spool.closedThisRun = []
        Spool.recover()
        check(Talk.shared.read == [sp.dir.lastPathComponent], "closed but never read: read again on the next start")
        check((try? String(contentsOf: mark, encoding: .utf8)) == "1", "the try is counted")
        Spool.closedThisRun = []
        Spool.recover()
        check(Talk.shared.read.count == 2, "a second try")
        Spool.closedThisRun = []
        Spool.recover()
        check(Talk.shared.read.count == 2, "never a third: left for Read again")
        Spool.markRead(sp.dir)
        check(!FileManager.default.fileExists(atPath: mark.path), "the transcript clears the mark")

        // Argon 6: the microphone stalls 6.5 s while the other side goes on: nothing of the other side is lost, and
        // his side gets silence for the gap so both files stay on one timeline
        guard let sp2 = Spool(call: true, app: "Test") else { print("FAIL: no spool 2"); exit(1) }
        let tape2 = Tape(), sys = SysAudio()
        tape2.attach(sp2, call: true); tape2.attach(sys: sys)
        sys.receive([Float](repeating: 0.5, count: 1600))
        _ = tape2.write(chunk, peak: 0.25)                       // in step
        sys.receive([Float](repeating: 0.5, count: 104000))      // 6.5 s while the microphone gave nothing
        let mixed = tape2.write(chunk, peak: 0.25)
        check(mixed?.count == chunk.count, "the live mix still gets one chunk's worth")
        let me2 = sp2.dir.appendingPathComponent("me.pcm"), them2 = sp2.dir.appendingPathComponent("them.pcm")
        check(size(them2) == (1600 + 104000) * 2, "the other side's 6.5 s backlog is written, not dropped (\(size(them2)))")
        check(size(me2) == size(them2), "his side gets silence for the gap: one timeline (\(size(me2)) vs \(size(them2)))")
        check(tape2.now().themSamples == 105600, "the strip reads the other side's count through the lock")
        // Argon 6: with no microphone at all the waiting sound stays bounded in memory
        sys.receive([Float](repeating: 0.1, count: SysAudio.most + 16000))
        // Argon 7: what came before stop() is kept, what comes after is not
        let rest = sys.stop()
        check(rest.count <= SysAudio.most && rest.count >= SysAudio.most - 16000 * 60, "the backlog is capped (\(rest.count))")
        sys.receive(chunk)
        check(sys.stop().isEmpty, "after stop nothing more is kept")
        _ = tape2.detach()?.close()

        // the recording window's Pause (17 November 2026): both sides are dropped together, the other side's stretch
        // is taken too, so after Resume the two files are still on one timeline
        guard let sp3 = Spool(call: true, app: "Test") else { print("FAIL: no spool 3"); exit(1) }
        let tape3 = Tape(), sys3 = SysAudio()
        tape3.attach(sp3, call: true); tape3.attach(sys: sys3)
        sys3.receive(chunk); _ = tape3.write(chunk, peak: 0.25)
        let me3 = sp3.dir.appendingPathComponent("me.pcm"), them3 = sp3.dir.appendingPathComponent("them.pcm")
        let before = size(me3)
        tape3.paused = true
        for _ in 0..<5 { sys3.receive(chunk); check(tape3.write(chunk, peak: 0.25) == nil, "paused: nothing for the live mix") }
        check(size(me3) == before && size(them3) == before, "paused: neither side is written (\(size(me3)), \(size(them3)))")
        check(tape3.now().meSamples == 1600, "paused: the counts stand still")
        tape3.paused = false
        sys3.receive(chunk); _ = tape3.write(chunk, peak: 0.25)
        check(size(me3) == before + 3200 && size(them3) == size(me3), "after Resume both sides go on in step (\(size(me3)), \(size(them3)))")
        tape3.paused = true
        _ = tape3.detach()?.close()
        check(!tape3.paused, "a new recording never starts paused")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("tape: all passed")
    }
}
'''


class CallTape(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_tape_writes_without_main_and_unread_recovery(self):
        source = (ROOT / 'app/Call.swift').read_text()
        start = source.index("/// The Mac's own sound (what the other side says)")
        end = source.index('/// Something waiting in the strip for a few seconds')
        header = 'import AppKit\nimport CoreAudio\nimport ScreenCaptureKit\n'
        with tempfile.TemporaryDirectory(prefix='drafter-tape-') as directory:
            path = Path(directory)
            (path / 'call.swift').write_text(header + source[start:end])
            (path / 'stubs.swift').write_text(STUBS)
            (path / 'main.swift').write_text(MAIN)
            (path / 'data').mkdir()
            built = subprocess.run(['swiftc', '-module-cache-path', str(path / 'cache'), '-parse-as-library',
                                    str(ROOT / 'app/CaptureRules.swift'), str(ROOT / 'app/MeetingRules.swift'), str(ROOT / 'app/SysWatchRules.swift'), str(path / 'call.swift'), str(path / 'stubs.swift'),
                                    str(path / 'main.swift'), '-o', str(path / 'check')], capture_output=True, text=True, timeout=180)
            self.assertEqual(built.returncode, 0, built.stderr[-3000:])
            run = subprocess.run([str(path / 'check'), str(path / 'data')], capture_output=True, text=True, timeout=180)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('tape: all passed', run.stdout)


class CallStatic(unittest.TestCase):
    """What must not come back in the source (read, not run)."""

    def test_focus_never_reads_its_own_window_off_main(self):
        import re
        source = (ROOT / 'app/Focus.swift').read_text()
        funcs = re.split(r'\n    (?=(?:@discardableResult\n    )?(?:private )?static func )', source)
        for body in funcs:
            m = re.match(r'(?:@discardableResult\n    )?(?:private )?static func (\w+)', body)
            if not m or m.group(1) in ('probeLoop',):   # the --probe CLI runs on its own main thread
                continue
            if re.search(r'AXUIElement(Copy|Set(?!MessagingTimeout))', body):
                self.assertTrue('offLimits' in body or 'ownPid' in body, m.group(1) + ' calls AX without the own-process guard')
        for name in ('windowTitle', 'screenContext', 'spot'):
            body = next(b for b in funcs if re.match(r'(?:private )?static func ' + name + r'\b', b))
            self.assertIn('offLimits', body, name)

    def test_recording_is_written_off_main_and_kept_at_the_end(self):
        voice = ''.join((ROOT / 'app' / f).read_text() for f in ('Voice.swift', 'TalkLive.swift', 'TalkRecord.swift', 'TalkFlow.swift'))
        call = (ROOT / 'app/Call.swift').read_text()
        heard = voice.split('    func heard(', 1)[1].split('\n    }\n', 1)[0]
        self.assertNotIn('spool?.add', heard, 'the main thread must not write the recording')
        self.assertIn('tape.write(s, peak: pk)', voice)
        self.assertNotIn('_ = sys?.stop()', voice, 'ending a take must not throw the other side away')
        self.assertNotIn('private var all:', call, 'the whole other side is never kept in memory')
        self.assertIn('Spool.markRead(dir)', voice)
        mic = (ROOT / 'app/Mic.swift').read_text().split('    func stop() {', 1)[1].split('\n    }\n', 1)[0]
        self.assertIn('done.wait', mic, 'stop waits until the delivered samples went through the sink')

    def test_captures_back_off(self):
        for f in ('Screen.swift', 'Shots.swift', 'Call.swift'):
            self.assertIn('Backoff(', (ROOT / 'app' / f).read_text(), f)


if __name__ == '__main__':
    unittest.main()
