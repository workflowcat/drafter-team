"""Run the actual topic model actions against an in-memory journal and synthetic UI edges.

No WindowModel initialization, app process, live data, network, or desktop interaction.
.venv/bin/python -B tests/test_topic_journal_actions.py
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

STUBS = r'''
import Foundation

enum Kind { case typed, said, copied, call
    var word: String { switch self { case .typed: return "typed"; case .said: return "spoken"; case .copied: return "copied"; case .call: return "call" } }
}
enum Clip { case text, image }
struct Entry { var shot = ""; var clip = Clip.text }
struct TapeItem {
    let id: String; var kind = Kind.typed; var text: String; var at: Double = 100
    var app = "Synthetic Notes"; var tags: [TapeTag] = []; var pinned = false
    var change: String?; var doc: String?; var shot: String?; var entry: Entry? = Entry()
    var ownDraft: Bool { id.hasPrefix("j:") }
    var current: String { change ?? text }
    var quick: String? { kind == .call ? nil : kind.word }
}
final class Quick {
    static let shared = Quick()
    func isPinned(_ q: String, _ text: String) -> Bool { fatalError("Must stay in synthetic preview") }
}
enum TapeBuild {
    static func rows(takes: [TapeItem], clips: [TapeItem], typed: [TapeItem], docs: [TapeItem], own: [JournalStore.Item]) -> [TapeItem] {
        (takes + clips + typed + docs + own.map { TapeItem(id: "j:" + $0.id, text: $0.text, at: $0.at, pinned: $0.pinned) }).sorted { $0.at > $1.at }
    }
}
final class WindowModel {
    var rows: [TapeItem] = []; var rowsGen = 0; var tapeTick = 0
    var takes: [TapeItem] = [], clips: [TapeItem] = [], typed: [TapeItem] = [], docs: [TapeItem] = []
    let journalStore = JournalStore(url: nil)
    var preview = true; var previewPins: Set<String> = []; var goneIds: Set<String> = []
    var editing: String?; var draft = ""; var picked: [String] = []; var chosen: String?; var status = ""
    var undos: [(name: String, run: () -> Void)] = []
    func leaveEditor() {
        if let id = editing { journalStore.update(String(id.dropFirst(2)), text: draft) }
        editing = nil // Simulate a real asynchronous rebuild that has not completed yet.
    }
    func refilter() {}
    func rebuildTape() {
        rows = TapeBuild.rows(takes: takes, clips: clips, typed: typed, docs: docs, own: journalStore.file.items).filter { !journalStore.isHidden($0.id) }
        rowsGen += 1
    }
    func undoLast() { undos.popLast()?.run() }
}
'''

CHECKS = r'''
@main struct Checks {
    static func check(_ value: Bool, _ name: String) { if !value { fatalError("FAIL: " + name) } }
    static func model() -> WindowModel {
        let m = WindowModel()
        m.typed = [TapeItem(id: "t:one", text: "Review station budget", at: 100), TapeItem(id: "t:pin", text: "Station budget drawings", at: 200, pinned: true)]
        m.previewPins = ["t:pin"]
        m.takes = [TapeItem(id: "v:two", kind: .said, text: "Review station budget tomorrow", at: 300)]
        m.docs = [TapeItem(id: "d:call", kind: .call, text: "Recording title", doc: "recording")]
        m.rebuildTape(); return m
    }
    static func main() {
        let m = model()
        let topic = m.topicTidy.clusters[0]
        check(topic.itemIds.count == 3, "all typing/voice sources, no recording")
        let preview = m.topicPreview(topic)
        m.journalStore.hide(["t:previous"])
        m.consolidateTopic(topic, archiveSources: true)
        let note = m.journalStore.file.items[0]
        check(note.text == preview && note.kind == "draft", "preview is the saved Markdown")
        check(Set(note.sources) == Set(topic.itemIds), "sources retained")
        check(m.journalStore.hidden == Set(["t:previous", "t:one", "v:two"]), "only unpinned sources archived")
        check(m.rows.contains { $0.id == "t:pin" } && !m.rows.contains { $0.id == "v:two" }, "active feed hides archived sources")
        m.journalStore.update(note.id, text: "Edited clean note")
        m.undoLast()
        check(!m.journalStore.isHidden("t:one") && m.journalStore.isHidden("t:previous"), "merge undo preserves prior archives")
        check(m.journalStore.isHidden("j:" + note.id) && m.journalStore.file.items[0].text == "Edited clean note", "merge undo keeps later note edits recoverable")
        m.restoreArchived(["j:" + note.id]); check(!m.journalStore.isHidden("j:" + note.id), "restore generated note")
        m.undoLast(); check(m.journalStore.isHidden("j:" + note.id), "undo restore")
        m.archiveItems(["t:pin", "d:call", "t:one", "missing"])
        check(m.journalStore.isHidden("t:one") && !m.journalStore.isHidden("t:pin") && !m.journalStore.isHidden("d:call"), "archive protects pins and recordings")
        m.undoLast(); check(!m.journalStore.isHidden("t:one"), "undo archive")
        let keep = model(), keepTopic = keep.topicTidy.clusters[0]
        keep.consolidateTopic(keepTopic, archiveSources: false)
        check(keep.journalStore.hiddenCount == 0, "archive toggle off")
        check(keep.topicTidy.clusters.isEmpty, "identical output is no longer offered")
        keep.consolidateTopic(keepTopic, archiveSources: false)
        check(keep.journalStore.file.items.count == 1, "stale selection cannot double-merge")
        keep.undoLast(); check(keep.topicTidy.clusters.count == 1, "undo offers original topic again")
        let edit = model()
        let source = edit.journalStore.add(kind: "draft", text: "Station budget draft", sources: [], pinned: false, at: 250)
        edit.rebuildTape()
        let old = edit.topicTidy.clusters[0]
        edit.editing = "j:" + source.id; edit.draft = "Final station budget revision with a new detail"
        edit.consolidateTopic(old, archiveSources: true)
        check(edit.journalStore.file.items.last!.text.contains(edit.draft), "merge saves pending edits before archiving")
        let image = model()
        image.clips = [TapeItem(id: "c:image", kind: .copied, text: "x", entry: Entry(clip: .image))]
        image.rebuildTape()
        check(!image.topicTidy.candidates.contains { $0.id == "c:image" }, "image clips are never text clutter")
        print("topic journal actions: all passed")
    }
}
'''


class TopicJournalActions(unittest.TestCase):
    def test_real_actions_with_synthetic_rows(self):
        source = (ROOT / "app/JournalModel.swift").read_text()
        actions = source.split("    // MARK: topics and reversible tidying\n", 1)[1].split("    // MARK: delete and undo", 1)[0]
        cache = source[source.index("struct TopicTidySnapshot {"):]
        with tempfile.TemporaryDirectory(prefix="topic-journal-test-") as folder:
            harness = Path(folder) / "actions.swift"
            binary = Path(folder) / "actions-test"
            harness.write_text(STUBS + "\nextension WindowModel {\n" + actions + "}\n" + cache + CHECKS)
            command = ["swiftc", "-O", "-parse-as-library", "app/TapeRules.swift", "app/ClipRules.swift", "app/EntityRules.swift",
                       "app/TopicClusterRules.swift", "app/JournalStore.swift", str(harness), "-o", str(binary)]
            built = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            print(run.stdout.strip())


if __name__ == "__main__":
    unittest.main()
