"""Screen context in the prompt (engine/prompt.py, 2026-11-14): today's look stays the default, the app's speaker marks
are taken off until the context sweep measures them, the structured tail keeps who said what under a budget, and the
prompt order stays cache friendly (head, then the screen, his text last). Made-up text only.
.venv/bin/python -B tests/test_prompt_context.py"""
import sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import prompt

MARKED = "Вони: Привіт! Ти бачив новий draft of the zebra plan?\nЯ: Так, глянув вчора\nВони: Окей, коли зідзвонимось? Може у четвер"


class Forms(unittest.TestCase):
    def test_plain_unmarked_is_todays_form(self):
        ctx = "line one of a page\nline two with words\n" + "x" * 2000
        self.assertEqual(prompt.screen_text(ctx, "plain", 1600), ctx.strip()[-1600:])

    def test_plain_takes_the_app_marks_off(self):
        out = prompt.screen_text(MARKED, "plain", 1600)
        self.assertNotIn("Вони:", out); self.assertNotIn("Я:", out)
        self.assertTrue(out.startswith("Привіт! Ти бачив") and out.endswith("у четвер"))

    def test_plain_leaves_bench_replay_marks(self):
        ctx = "Олена: де файл?\nЯ: зараз скину"
        self.assertEqual(prompt.screen_text(ctx, "plain", 1600), ctx)

    def test_raw(self):
        self.assertEqual(prompt.screen_text(MARKED, "raw", 20), MARKED[-20:])

    def test_tail_keeps_who_said_what(self):
        self.assertEqual(prompt.screen_text(MARKED, "tail", 1600), MARKED)
        self.assertEqual(prompt.screen_text(MARKED, "tail-plain", 1600).splitlines()[1], "Так, глянув вчора")

    def test_tail_under_a_tight_budget(self):
        long = "довге питання " * 20
        ctx = f"Вони: old one\nЯ: old reply\nВони: {long}\nЯ: my answer\nВони: short follow-up"
        self.assertEqual(prompt.screen_text(ctx, "tail", 60), "Я: my answer\nВони: short follow-up")
        end = prompt.screen_text("Я: hi\nВони: " + long, "tail", 50)
        self.assertTrue(end.startswith("Вони: ") and long.strip().endswith(end[len("Вони: "):].strip()))
        self.assertLessEqual(len(end), 50 + 7)

    def test_turns(self):
        t = prompt.turns("Вони: перше\nпродовження\nАсистент: answer\nЯ: моє")
        self.assertEqual(t, [("them", "перше продовження"), ("ai", "answer"), ("me", "моє")])
        self.assertEqual(prompt.turns("no marks here\nsecond"), [(None, "no marks here"), (None, "second")])

    def test_empty(self):
        for f in ("plain", "raw", "tail"): self.assertEqual(prompt.screen_text("", f), "")
        self.assertEqual(prompt.screen_text(MARKED, "tail", 0), "")


class Order(unittest.TestCase):
    def test_tail_order(self):
        t = prompt.tail("Я пишу", app="Beeper", title="Олена", context=MARKED, mine="старе моє")
        i_app, i_mine, i_ctx, i_before = t.index("[Beeper"), t.index("Мої раніші"), t.index("На екрані перед цим"), t.rindex("Я пишу")
        self.assertTrue(i_app < i_mine < i_ctx < i_before, "app line, his older lines, the screen, his text last")
        self.assertTrue(t.endswith("Я пишу"))
        self.assertNotIn("Вони:", t)   # default form: marks off

    def test_no_context_no_block(self):
        self.assertNotIn("На екрані", prompt.tail("text", app="Notes", context="   "))


if __name__ == "__main__":
    unittest.main()
