"""Per-person memory (engine/people.py): which chat is on screen from fingerprints of its lines, his older lines for
the prompt, and lines he sends joining that chat at once."""
import sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import people


class Find(unittest.TestCase):
    def setUp(self):
        self.marks = {}
        for chat, lines in {"a": ["Привіт, як там проєкт по складу?", "давай завтра о десятій", "окей, скинь адресу будь ласка"],
                            "b": ["did you see the new deck yet", "окей, скинь адресу будь ласка", "lunch on friday works"]}.items():
            for l in lines:
                m = people.mark(l)
                self.marks[m] = chat if self.marks.get(m) in (None, chat) else ""

    def test_two_lines_of_one_chat_find_it(self):
        self.assertEqual(people.find(self.marks, "ui text\nПривіт, як там проєкт по складу?\nдавай  завтра о десятій\n"), "a")

    def test_a_line_in_two_chats_or_one_line_finds_nothing(self):
        self.assertIsNone(people.find(self.marks, "окей, скинь адресу будь ласка\nlunch on friday works"))
        self.assertIsNone(people.find(self.marks, "did you see the new deck yet"))
        self.assertEqual(people.mark("ок"), "")

    def test_signed_lines_are_claudes(self):
        self.assertTrue(people.signed("Claude: готово"))
        self.assertTrue(people.signed("клод: ок"))
        self.assertFalse(people.signed("claude code has it"))


class Memory(unittest.TestCase):
    def test_earlier_skips_lines_on_screen_and_keeps_newest_last(self):
        mine = ["перше повідомлення тут", "друге повідомлення тут", "третє, вже на екрані"]
        self.assertEqual(people.earlier(mine, "третє, вже на екрані"), "перше повідомлення тут\nдруге повідомлення тут")
        self.assertEqual(people.earlier(mine, "", n=1), "третє, вже на екрані")

    def test_sent_line_joins_its_chat(self):
        with tempfile.TemporaryDirectory() as d:
            P = people.People(Path(d) / "people.json")
            on_screen = "давай завтра о десятій зранку\nокей, тоді до зустрічі в офісі"
            P.chats = {"a": {"mine": ["рядок номер %d про склад і накладні" % i for i in range(25)], "key": "1"}}
            for l in on_screen.splitlines(): P._mark(people.mark(l), "a")
            first = P.block(on_screen)
            self.assertTrue(first.endswith("рядок номер 24 про склад і накладні"))
            self.assertEqual(P.add(on_screen, "Claude: не моє"), None)
            self.assertEqual(P.add(on_screen, "супер, беру ноутбук"), "a")
            self.assertEqual(P.chats["a"]["mine"][-1], "супер, беру ноутбук")
            self.assertEqual(P.block(on_screen), first)                          # fixed for the run: the cache keeps it
            self.assertEqual(P.block("давай завтра о десятій зранку"), first)     # one line of the chat found last is enough
            self.assertEqual(P.block("something else entirely here"), "")
            P.save()
            self.assertEqual(people.People(Path(d) / "people.json").chat_for(on_screen), "a")



class Regressions(unittest.TestCase):
    def test_full_visible_messages_are_checked_before_truncation(self):
        long = 'synthetic long message ' * 15
        multi = 'first message line\nsecond message line'
        for message in (long, multi):
            for screen in (message, 'Я: ' + message, 'header\nЯ: ' + message + '\nfooter'):
                self.assertEqual(people.earlier([message], screen), '')
        self.assertEqual(people.earlier([long], 'Я: ' + long[:200]), '')
        self.assertEqual(people.earlier(['a distinct old message'], 'a distinct old message extra'), 'a distinct old message')

    def test_short_replies_require_a_whole_visible_line(self):
        for reply in ('дякую', 'добре'):
            self.assertEqual(people.earlier([reply], 'нам ' + reply + ' працюється'), reply)
            self.assertEqual(people.earlier([reply], 'header\nЯ: ' + reply + '\nfooter'), '')
        self.assertEqual(people.earlier(['one two'], 'one\ntwo'), 'one two')

    def test_cached_block_filters_newly_visible_message_and_prefill_does_not_move_chat(self):
        with tempfile.TemporaryDirectory() as d:
            p = people.People(Path(d) / 'people.json')
            for chat in ('old', 'current'):
                p.chats[chat] = {'mine': [f'{chat} message number {i}' for i in range(5)]}
                for line in p.chats[chat]['mine']: p._mark(people.mark(line), chat)
            old = '\n'.join(p.chats['old']['mine'][:2])
            current = '\n'.join(p.chats['current']['mine'][:2])
            p.block(current)
            self.assertEqual(p.last, 'current')
            p.block(old, remember=False)
            self.assertEqual(p.last, 'current')
            self.assertEqual(p.chat_for(p.chats['current']['mine'][0]), 'current')
            first = p.block(old)
            self.assertIn('old message number 4', first)
            self.assertNotIn('old message number 4', p.block(old + '\nold message number 4'))

    def test_empty_marks_are_bounded_and_recent_collisions_stay_ambiguous(self):
        with tempfile.TemporaryDirectory() as d:
            p = people.People(Path(d) / 'people.json')
            p.chats = {'a': {}, 'b': {}}
            p.marks = {str(i): '' for i in range(people.MAX_EMPTY_MARKS + 30)}
            p.marks.update({'live': 'a', 'dead': 'gone'})
            p.save()
            self.assertEqual(sum(c == '' for c in p.marks.values()), people.MAX_EMPTY_MARKS)
            self.assertNotIn('0', p.marks)
            self.assertNotIn('dead', p.marks)
            self.assertEqual(p.marks['live'], 'a')
            last = str(people.MAX_EMPTY_MARKS + 29)
            p._mark(last, 'a')
            self.assertEqual(p.marks[last], '')


if __name__ == "__main__":
    unittest.main()
