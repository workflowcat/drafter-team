"""Local knowledge, no models or services. Importing this module reads nothing.

Build explicitly or from nightly. Readers swap whole packs on mtime changes.
All Aleph queries exclude private rows before fetching them.
"""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
KINDS = {'person', 'project', 'org', 'team', 'tool', 'repo'}
NAME_SHARE_FLOOR = 0.03
WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)
COMMON = set('base clear broker personal grant mark will can may bill hope rose lily ruby max team work project tool code app new old the and for with from this that have use make time email phone'.split())
FIRST = dict(zip(
    'Юра Юрій Ганна Анна Максим Аліна Сергій Андрій Олександр Олексій Іван Ірина Олена Марія Наталія Тетяна Дмитро Микола Павло Петро Богдан Віктор Денис Роман Тарас'.split(),
    'Yura Yurii Hanna Anna Maksym Alina Serhii Andrii Oleksandr Oleksii Ivan Iryna Olena Mariia Nataliia Tetiana Dmytro Mykola Pavlo Petro Bohdan Viktor Denys Roman Taras'.split()))
EXTRA = {'Yuriy': 'Юрій', 'Yuri': 'Юрій', 'Serhiy': 'Сергій', 'Sergiy': 'Сергій', 'Andriy': 'Андрій', 'Maxim': 'Максим', 'Anna': 'Анна'}
TRANSLIT = dict(zip('абвгґдеєжзиіїйклмнопрстуфхцчшщьюя',
    ['a','b','v','h','g','d','e','ie','zh','z','y','i','yi','i','k','l','m','n','o','p','r','s','t','u','f','kh','ts','ch','sh','shch','','iu','ia']))
CYRILLIC = re.compile(r"[А-Яа-яІіЇїЄєҐґьЬ’ʼ'-]+")
HALF = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*$")
FEMALE = set('Ганна Анна Аліна Ірина Олена Марія Наталія Тетяна Ольга Леся Любов Нінель Адель'.split())
MALE = set('Юра Юрій Максим Сергій Андрій Олександр Олексій Іван Дмитро Микола Павло Петро Богдан Віктор Денис Роман Тарас Микита Ілля Кузьма Лука Сава Віталій'.split())
FIRST.update({'Віталій': 'Vitalii', 'Микита': 'Mykyta', 'Любов': 'Liubov', 'Ольга': 'Olha'})


def tokens(text): return [w for w in WORD.findall(text or '') if len(w) >= 3]


def transliterate(word):
    if CYRILLIC.fullmatch(word):
        out = ''.join(({'є':'ye','ї':'yi','й':'y','ю':'yu','я':'ya'}.get(c, TRANSLIT.get(c, c)) if i == 0 else TRANSLIT.get(c, c))
                      for i, c in enumerate(word.lower()))
    else: return ''
    return out.capitalize() if word[:1].isupper() else out


def first_variants(word):
    for uk, latin in FIRST.items():
        if word.casefold() in (uk.casefold(), latin.casefold()): return {uk, latin}
    for latin, uk in EXTRA.items():
        if word.casefold() == latin.casefold(): return {uk, FIRST.get(uk, latin), latin}
    other = transliterate(word)
    return {word, other} - {''}


def case_forms(word, female=False, surname=False):
    """Common Ukrainian endings; no claim of a complete morphological dictionary.
    Female consonant/-ko surnames are invariant. The builder skips unknown genders.
    """
    if not CYRILLIC.fullmatch(word): return set()
    low = word.lower()
    if female and not surname and low == 'любов': return {'Любові', 'Любов’ю'}
    if female and not low.endswith(('а', 'я')): return set()
    if low.endswith('ська'): stem, ends = word[:-1], ['ої','ій','у','ою']
    elif low.endswith('ський') or (surname and low.endswith('ий')): stem, ends = word[:-2], ['ого','ому','им']
    elif low.endswith('ій'): stem, ends = word[:-1], ['я','ю','єм','єві']
    elif low.endswith('ий'): stem, ends = word[:-2], ['ого','ому','им']
    elif low.endswith('ія'): stem, ends = word[:-1], ['ї','ю','єю']
    elif low.endswith('я'): stem, ends = word[:-1], ['і','ю','ею']
    elif low.endswith('а'):
        stem, ends = word[:-1], ['и','і','у','ою']
    elif low.endswith('єць'): stem, ends = word[:-3] + 'й', ['ця','цю','цем','цеві']
    elif low.endswith('ець'): stem, ends = word[:-3], ['ця','цю','цем','цеві']
    elif low.endswith('ь'): stem, ends = word[:-1], ['я','ю','ем','еві']
    elif low.endswith('о'): stem, ends = word[:-1], ['а','у','ом','ові']
    elif low[-1:] in 'бвгґджзклмнпрстфхцчшщ': stem, ends = word, ['а','у','ом','ові']
    else: return set()
    out = {stem + end for end in ends}
    # Palatalisation in the dative/locative of -а names (Ольга -> Ользі).
    if low.endswith('а') and stem[-1:].lower() in 'гкх':
        out.discard(stem + 'і'); out.add(stem[:-1] + {'г':'з','к':'ц','х':'с'}[stem[-1].lower()] + 'і')
    return out


def person_forms(entry):
    labels = [entry['name']] + entry['aliases']
    cyr_labels = [tokens(label) for label in labels if tokens(label) and all(CYRILLIC.fullmatch(w) for w in tokens(label))]
    firsts = {parts[0] for parts in cyr_labels if parts[0] in FEMALE | MALE}
    for label in labels:
        parts = tokens(label)
        if parts:
            firsts.update(v for v in first_variants(parts[0]) if v in FEMALE | MALE)
    genders = {w in FEMALE for w in firsts}
    gender = next(iter(genders)) if len(genders) == 1 else None
    surnames = {w for parts in cyr_labels if len(parts) > 1 and parts[0] in firsts for w in parts[1:]}
    forms = set()
    for label in labels:
        for token in tokens(label):
            # Reverse transliteration is inherently lossy (-yi/-ii, soft signs). Only an
            # attested alias or the first-name table supplies Ukrainian spelling.
            variants = first_variants(token) if token in firsts or any(token in first_variants(f) for f in firsts) else {token, transliterate(token)} - {''}
            forms.update(variants)
            for v in variants:
                if gender is not None and (v in firsts or v in surnames):
                    forms.update(case_forms(v, female=gender, surname=v in surnames))
                    if v in firsts:
                        if v.endswith('а'): forms.add(v[:-1] + 'ою')
                        elif v.endswith('я') and v[-2:-1] in 'аеєиіїоуюя':
                            forms.add(v[:-1] + 'єю')
    return {w for w in forms if w[:1].isupper()}


def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f: f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def sent_lines(path):
    """Caller opts in to reading their own sent history. Never drafts/received messages."""
    try:
        with Path(path).open() as f:
            for line in f:
                try: row = json.loads(line)
                except ValueError: continue
                if isinstance(row.get('text'), str) and '⟦drafter-test⟧' not in row['text']: yield row['text']
    except FileNotFoundError: return


def usage(entries, lines):
    """One hit per entry per sent line, plus frequent lowercase words for ambiguity guards."""
    counts, lower = Counter(), Counter()
    index = {}
    for i, entry in enumerate(entries):
        for w in entry['tokens'] + entry['forms']: index.setdefault(w.casefold(), set()).add(i)
    for line in lines:
        hits = set()
        for w in tokens(line):
            if w.islower(): lower[w.casefold()] += 1
            for i in index.get(w.casefold(), ()):
                if w.casefold() not in entries[i]['common'] or w[:1].isupper(): hits.add(i)
        counts.update(hits)
    return counts, lower


def build(out=ROOT / 'data/know.json', *, db=None, dictionary=None, snippets=None, lines=(), now=None, common=(), spell_known=None, contacts=None):
    import integrations
    no_aleph = db is None and not integrations.available('aleph')    # optional: off, the pack is built from the rest
    db = Path(db) if db is not None else Path(integrations.local.setting('aleph', 'db') or '/nonexistent/aleph.db')
    dictionary = Path(dictionary) if dictionary is not None else ROOT / 'data/words.json'
    snippets = Path(snippets) if snippets is not None else ROOT / 'data/snippets.json'
    now = time.time() if now is None else now
    entries = []
    # Fail closed on a missing/broken source: do not replace yesterday's pack with partial knowledge.
    if no_aleph:
        con = sqlite3.connect(':memory:')
        con.executescript('CREATE TABLE things(id,kind,name,short,scope); CREATE TABLE names(name,thing); '
                          'CREATE TABLE facts(subj,rel,value,since,obj,until,scope);')
    else:
        con = sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    with con:
        rows = con.execute("SELECT id, kind, name, short FROM things WHERE coalesce(scope,'work') != 'private' AND kind IN ('person','project','org','team','tool','repo')").fetchall()
        aliases = {}
        for row in con.execute("SELECT n.name, n.thing FROM names n JOIN things t ON t.id=n.thing WHERE coalesce(t.scope,'work') != 'private' AND t.kind IN ('person','project','org','team','tool','repo')"):
            aliases.setdefault(row['thing'], []).append(row['name'])
        facts = {}
        for row in con.execute("""SELECT f.subj,f.rel,f.value,f.since,o.name AS object_name FROM facts f
            JOIN things s ON s.id=f.subj LEFT JOIN things o ON o.id=f.obj
            WHERE coalesce(s.scope,'work') != 'private' AND coalesce(f.scope,'work') != 'private'
            AND coalesce(o.scope,'work') != 'private' AND (f.until IS NULL OR f.until=0 OR f.until>?)
            AND f.rel IN ('handle','role','works_at','last_contact')""", (now,)):
            facts.setdefault(row['subj'], []).append(dict(row))
        for row in rows:
            e = {'id': row['id'], 'name': row['name'], 'kind': row['kind'], 'aliases': sorted(set(aliases.get(row['id'], []) + ([row['short']] if row['short'] else []))),
                 'handles': {}, 'role': '', 'org': '', 'last_contact': 0}
            for fact in facts.get(row['id'], []):
                val = (fact['value'] or '').strip()
                if fact['rel'] == 'last_contact': e['last_contact'] = max(e['last_contact'], fact['since'] or 0)
                elif fact['rel'] == 'role': e['role'] = ' '.join(val.split())[:160]
                elif fact['rel'] == 'works_at': e['org'] = ' '.join((fact['object_name'] or val).split())[:160]
                elif fact['rel'] == 'handle':
                    key, value = handle(val)
                    if key: e['handles'].setdefault(key, []).append(value)
            e['handles'] = {k: sorted(set(v)) for k, v in e['handles'].items()}
            entries.append(e)
    con.close()
    if contacts is not None:
        from contacts import merge
        entries = merge(entries, contacts)
    safe_names = {n.casefold() for e in entries for n in [e['name']] + e['aliases']}
    def read(path, default):
        try: return json.loads(path.read_text())
        except FileNotFoundError: return default
    for w in read(dictionary, {}).get('words', []):
        w = {'text': w} if isinstance(w, str) else w
        name = w.get('text', '').strip()
        if not name or name.casefold() in safe_names: continue
        # Old Aleph seeds may include records since made private; only current public records survive.
        if w.get('scope') == 'private' or w.get('source', '').startswith('aleph') or w.get('source') in ('people', 'work'): continue
        entries.append({'name': name, 'kind': 'person' if w.get('kind') == 'name' else 'term', 'aliases': [], 'handles': {}, 'role': '', 'org': ''})
    for key, value in read(snippets, {}).items():
        if isinstance(value, str) and value.strip():
            # Do not turn URLs, addresses or fill-in placeholders into word completions.
            if re.search(r'[@/:{}]', value): continue
            entries.append({'name': value.strip(), 'kind': 'phrase', 'aliases': [], 'handles': {}, 'role': '', 'org': '', 'snippet': key})
    ordinary = COMMON | {w.casefold() for w in common}
    try: ordinary |= {w for w in Path('/usr/share/dict/words').read_text().splitlines() if w.islower()}
    except OSError: pass
    for e in entries:
        ts = set() if e.get('cards_only') else set(tokens(e['name']))
        if not e.get('cards_only'):
            for alias in e['aliases']: ts.update(tokens(alias))
        forms = set()
        if e['kind'] == 'person' and not e.get('cards_only'):
            # Contacts get forms only from an actual Cyrillic name, never guessed Latin.
            if e.get('source') != 'contacts' or CYRILLIC.fullmatch(e['name'].replace(' ', '')):
                forms = person_forms(e)
        e['tokens'], e['forms'] = sorted(ts), sorted(w for w in forms - ts if w[:1].isupper())
        e['common'] = sorted({w.casefold() for w in ts | forms if w.casefold() in ordinary or (spell_known and spell_known(w.lower()))})
    lines = list(lines)
    _, lower = usage(entries, lines)
    for e in entries:
        e['common'] = sorted(set(e['common']) | {w.casefold() for w in e['tokens'] + e['forms'] if lower[w.casefold()] >= 5})
    counts, _ = usage(entries, lines)
    for i, e in enumerate(entries):
        last = e.pop('last_contact', 0)
        age = max(0, now - last) / 86400
        e['heat'] = round((0.25 if e.get('source') == 'contacts' else 1) * (1 + counts[i] + (10 * math.exp(-age / 30) if last else 0)), 4)
    pack = {'version': 1, 'built': now, 'entries': entries}
    atomic(Path(out).with_name('known-words.txt'), '\n'.join(sorted({w for e in entries for w in e['tokens'] + e['forms']})) + '\n')
    atomic(out, json.dumps(pack, ensure_ascii=False, indent=1) + '\n')
    return pack


def handle(value):
    if re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value): return 'email', value
    if value.startswith('tg:') and value[3:].strip(): return 'tg', value[3:].strip()
    phone = re.sub(r'^(?:tel|phone):\s*', '', value)
    if re.fullmatch(r'\+?[\d ()-]{7,}', phone) and (phone.startswith('+') or phone != value or re.search(r'[ ()-]', phone)):
        return 'phone', phone
    return None, None  # chat IDs and other networks are not phone numbers


class Pack:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None and str(path) != 'none' else None
        self.stamp = None
        self.entries = []
        self.offered = 0

    def reload(self):
        if self.path is None: return
        try:
            st = self.path.stat(); stamp = (st.st_mtime_ns, st.st_size)
            if stamp == self.stamp: return
            self.stamp = stamp  # failed decodes are retried only when the file changes
            data = json.loads(self.path.read_text())
            entries = data['entries']
            if not isinstance(entries, list): return
            # A corrupt/hand-edited pack cannot introduce a private card.
            self.entries = [e for e in entries if e.get('scope') != 'private']
            self.stamp = stamp
        except FileNotFoundError:
            self.entries, self.stamp = [], None
        except (OSError, ValueError, KeyError, TypeError, AttributeError): pass  # retain last valid pack

    def snapshot(self):
        """This request's view. With the names reference beside the pack (data/names.json, engine/names.py, 2026-11-15)
        the word finisher and booster read that instead; DRAFTER_NAMES=0 keeps this pack."""
        names = self.names_view()
        if names is not None: return names
        self.reload()
        view = Pack()
        view.entries, view.stamp = self.entries, self.stamp
        return view

    def names_view(self):
        if self.path is None or os.environ.get('DRAFTER_NAMES') == '0': return None
        path = self.path.with_name('names.json')
        now = time.monotonic()   # whether the file is there: looked up at most every 30 s, not on every request
        if now - getattr(self, '_names_checked', -1e9) > 30:
            self._names_checked, self._names_there = now, os.path.exists(path)
        if not self._names_there: return None
        if getattr(self, '_names', None) is None or self._names.path != path:
            import names
            self._names = names.Pack(path)
        view = self._names.snapshot()
        return view if view.entries else None

    def finish(self, before, own_counts=None, prefix_totals=None):
        self.reload()
        m = HALF.search(before)
        if not m or len(m.group()) < 2 or not m.group()[0].isupper(): return ''
        typed = m.group(); candidates = set()
        for e in self.entries:
            if e.get('cards_only') or e['kind'] not in KINDS: continue
            for w in e['tokens'] + e['forms']:
                if not w[:1].isupper() or w.casefold() in e['common']: continue
                if w == typed: return ''
                if w.startswith(typed) and len(w) > len(typed): candidates.add(w)
        if len(candidates) != 1: return ''
        name = next(iter(candidates))
        used = (own_counts or {}).get(name.casefold(), 0)
        competing = (prefix_totals or {}).get(typed.casefold(), 0) - used
        if used < 1 and (len(typed) < 3 or competing >= 2): return ''
        if competing >= 2 and used < NAME_SHARE_FLOOR * competing: return ''
        return name[len(typed):]

    def targets(self, before, context='', title=''):
        self.reload()
        m = HALF.search(before)
        if not m or len(m.group()) < 2 or not m.group()[0].isupper(): return []
        typed = m.group()
        screen = set(tokens(context + '\n' + title))
        weights = {}
        for e in self.entries:
            if e.get('cards_only') or e['kind'] not in KINDS: continue
            for w in e['tokens'] + e['forms']:
                if w.casefold() in e['common']: continue
                if w in screen and w[:1].isupper() and w.startswith(typed) and len(w) > len(typed):
                    rest = w[len(typed):]
                    weights[rest] = max(weights.get(rest, 0), max(.25, e.get('heat', 1)))
        total = sum(weights.values()) or 1
        return [(w, n / total) for w, n in sorted(weights.items())]

    def people(self, query):
        self.reload(); q = query.strip().lstrip(';').casefold()
        if len(q) < 2: return []
        return sorted((e for e in self.entries if e['kind'] == 'person' and e.get('handles') and
                       any(w.casefold().startswith(q) for w in [e['name']] + e['aliases'] + e['tokens'] + e['forms'])),
                      key=lambda e: (-e.get('heat', 1), e['name']))[:30]

    def stats(self):
        self.reload()
        return {'entries': len(self.entries), 'offered': self.offered}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['build'])
    ap.add_argument('--out', type=Path, default=ROOT / 'data/know.json')
    args = ap.parse_args()
    from contacts import refresh
    people = refresh()
    pack = build(args.out, lines=sent_lines(ROOT / 'data/typed.jsonl'), contacts=people)
    print(f"knowledge: {len(pack['entries'])} entries -> {args.out}")
    # the entity store next to it (engine/entities.py): its own failure never fails this build
    try:
        import entities
        store = entities.build(contacts=people or None, lines=entities.sent_rows(ROOT / 'data/typed.jsonl'),
                               chats=entities.chat_lines(ROOT / 'data/people.json'))
        print(f"entities: {len(store['records'])} records" + (f", kept the last {', '.join(store['failed'])}" if store['failed'] else ''))
    except Exception as e:
        print(f"entities: not built ({type(e).__name__})")
