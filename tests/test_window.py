"""server.window: the context window's start stays put while the text only grows, so the prompt cache keeps it."""
import unittest
from server_src import lift


def load():
    return lift('window', 'WINDOWS', 'WINDOWS_LOCK')['window']


class Window(unittest.TestCase):
    def test_short_text_is_whole(self):
        self.assertEqual(load()(('a', 'b', 'ctx'), 'short chat', 1000), 'short chat')

    def test_start_stays_while_text_grows(self):
        w = load()
        chat = '\n'.join(f'line {i} ' + 'synthetic words ' * 6 for i in range(40))
        first = w(('a', 'b', 'ctx'), chat, 1000)
        later = w(('a', 'b', 'ctx'), chat + '\nThem: ok, tomorrow at 10?', 1000)
        self.assertTrue(later.startswith(first))
        self.assertTrue(first.startswith('line '))      # starts at a line

    def test_jumps_when_half_again_as_long(self):
        w = load()
        chat = '\n'.join(f'line {i} ' + 'synthetic words ' * 6 for i in range(40))
        first = w(('a', 'b', 'ctx'), chat, 1000)
        grown = chat + '\nmore synthetic text' * 40
        self.assertLessEqual(len(w(('a', 'b', 'ctx'), grown, 1000)), 1000)
        self.assertFalse(w(('a', 'b', 'ctx'), grown, 1000).startswith(first[:48]))

    def test_screens_do_not_share_a_start(self):
        w = load()
        one = '\n'.join(f'chat one {i} ' + 'words ' * 10 for i in range(30))
        two = '\n'.join(f'chat two {i} ' + 'words ' * 10 for i in range(30))
        w(('a', 'one', 'ctx'), one, 1000)
        self.assertTrue(w(('a', 'two', 'ctx'), two, 1000).startswith('chat two'))

    def test_speculation_crossing_boundary_does_not_move_real_anchor(self):
        w = load()
        key = ('Beeper', 'same window', 'before')
        text = ''.join(chr(0x400 + i) for i in range(250))
        first = w(key, text, 100)
        anchor = dict(w.__globals__['WINDOWS'])
        speculative = w(key, text + 'z' * 60, 100, remember=False)
        self.assertTrue(speculative.startswith(first))
        self.assertEqual(w.__globals__['WINDOWS'], anchor)
        self.assertTrue(w(key, text + 'x', 100).startswith(first))
        w(('new', '', 'ctx'), text, 100, remember=False)
        self.assertNotIn(('new', '', 'ctx'), w.__globals__['WINDOWS'])

    def test_near_1200_speculation_retains_prefix_for_each_real_key(self):
        w = load()
        key = ('Beeper', '', 'before')
        text = ''.join(chr(0x1000 + i) for i in range(1200))
        w(key, text[:801], 800)
        for end in range(1180, 1201):
            real = w(key, text[:end], 800)
            ahead = w(key, text[:end] + 'x' * 40, 800, remember=False)
            following = w(key, text[:end + 1], 800)
            self.assertTrue(ahead.startswith(real))
            self.assertTrue(following.startswith(real))
            self.assertGreater(len(real), 1100)  # the shared prefix survives, no full re-prefill



class ConcurrentWindow(unittest.TestCase):
    def test_many_screens_share_bounded_locked_cache(self):
        from concurrent.futures import ThreadPoolExecutor
        w = load()
        text = 'synthetic words ' * 150
        with ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(lambda i: w(('app', str(i), 'ctx'), text, 1000), range(1000)))
        self.assertTrue(all(rows))
        self.assertLessEqual(len(w.__globals__['WINDOWS']), 200)


if __name__ == "__main__":
    unittest.main()
