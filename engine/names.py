"""The names reference (2026-11-15): one local entry per name the user uses - a person, project, company, place or term - with
its spellings, Ukrainian case forms, short forms, mishearings, phones, emails, links and where it shows up. Built from
the stores that already exist; importing this module reads nothing.

    .venv/bin/python engine/names.py build      # data/names.json, then the derived files below
    .venv/bin/python engine/names.py derive     # only the derived files, from data/names.json (after an edit)
    .venv/bin/python engine/names.py stats      # counts only

Inputs (all in data/, all optional; a missing one gives fewer entries, never an error):
- entities.json (engine/entities.py): the folded records - people deduped, twins folded, relations, case-form surfaces.
- know.json (engine/know.py): tokens, case forms, ordinary-word guards, and the dictionary's leftover terms.
- words.json (engine/dictionary.py): the user's dictionary words and what voice heard for them.
- people.json (the user's own lines per Beeper chat), corpus.jsonl and typed.jsonl (the user's lines): context counts only.
- names-edits.json: the user's edits on the Names page (spell, merge, hide), applied on every build.

Derived (each written whole, in place):
- known-words.txt: every name token and form, for autocorrect (was written by know.py; a superset of it).
- words.json `terms` order and `heard`: through dictionary.save (the shape engine/voice.py reads).
Readers: engine/words.py (finisher and booster through `Pack`), engine/voice.py (Whisper hint), app/Names.swift.

Private: entities marked private never enter. Nothing here leaves the Mac.
"""
import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_dir import data_dir  # noqa: E402
DATA = data_dir()

KINDS = ('person', 'project', 'company', 'place', 'term')
KIND_OF = {'person': 'person', 'name': 'person', 'project': 'project', 'tool': 'project', 'repo': 'project',
           'org': 'company', 'team': 'company', 'company': 'company', 'place': 'place', 'doc': 'term', 'term': 'term'}
WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)
HALF = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*$")
CYR = re.compile(r"[А-Яа-яІіЇїЄєҐґ]")
TEST = '⟦drafter-test⟧'
CHAT_IDS_KEPT = 12
VOICE_TERMS = 60


def fold(s): return ' '.join(str(s or '').casefold().replace('’', "'").replace('ʼ', "'").split())
def toks(s): return [w for w in WORD.findall(s or '') if len(w) >= 2]
def is_uk(s): return bool(CYR.search(s or ''))
def day(ts): return time.strftime('%Y-%m-%d', time.localtime(ts)) if ts else ''


def read_json(path, default):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return default


def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f: f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def blank(eid, kind, name):
    return {'id': eid, 'kind': kind, 'uk': name if is_uk(name) else '', 'latin': '' if is_uk(name) else name,
            'forms': [], 'short': [], 'heard': [], 'phones': [], 'emails': [], 'links': [], 'common': [],
            'context': {'lines': 0, 'chats': 0, 'chat_ids': [], 'apps': {}, 'last_seen': ''},
            'sources': [], 'card': False, 'hidden': False}


def display(e): return e.get('uk') or e.get('latin') or ''


def labels(e):
    """Spellings that name the entry as a whole: canonical names and short forms."""
    return [x for x in [e.get('uk'), e.get('latin')] + list(e.get('short', [])) if x]


def surfaces(e):
    """Every single word that names the entry (tokens of its names, short forms, case forms), as written."""
    out = []
    for x in labels(e) + list(e.get('forms', [])):
        for w in toks(x):
            if w not in out: out.append(w)
    return out


def add_unique(lst, values, key=fold):
    seen = {key(x) for x in lst}
    for v in values:
        if v and key(v) not in seen: lst.append(v); seen.add(key(v))
    return lst


# ---- gather -------------------------------------------------------------------------------------------------------

def from_entities(store):
    """Entity records -> entries (twins folded into their main record), id map, form surfaces."""
    records = store.get('records') or []
    out, index_of = {}, {}
    main = {r['id']: r.get('twin_of') for r in records if isinstance(r, dict)}
    for r in records:
        if not isinstance(r, dict) or r.get('private') or r.get('twin_of'): continue
        names = r.get('names') or {}
        name = r.get('name') or ''
        e = blank(r['id'], KIND_OF.get(r.get('kind'), 'term'), name)
        e['uk'] = names.get('uk') or e['uk']
        e['latin'] = names.get('en') or e['latin']
        add_unique(e['short'], [a for a in r.get('aliases', []) if fold(a) not in {fold(e['uk']), fold(e['latin'])}])
        h = r.get('handles') or {}
        e['phones'] = list(h.get('phone', [])); e['emails'] = list(h.get('email', []))
        e['links'] = [x['id'] for x in r.get('relations') or [] if isinstance(x, dict) and x.get('id')] or list(r.get('related') or [])
        e['sources'] = sorted({s.get('system', '') for s in r.get('sources', []) if s.get('system')}) + ['entities']
        e['card'] = bool(r.get('cards_only'))
        e['_ids'] = {s.get('id') for s in r.get('sources', []) if s.get('id')} | {r['id']}
        out[r['id']] = e
    for i, r in enumerate(records):
        if isinstance(r, dict): index_of[i] = r.get('twin_of') or r['id']
    for r in records:   # a twin's short names and links join its main record
        if isinstance(r, dict) and r.get('twin_of') in out:
            m = out[r['twin_of']]
            add_unique(m['short'], [r.get('name')] + list(r.get('aliases', [])))
            m['short'] = [s for s in m['short'] if fold(s) not in {fold(m['uk']), fold(m['latin'])}]
    for surface, hits in (store.get('surfaces') or {}).items():
        for i, how in hits:
            eid = index_of.get(i)
            # the store keeps surfaces folded; a case form of a name starts each word with a capital
            if eid in out and how == 'form': add_unique(out[eid]['forms'], [' '.join(w[:1].upper() + w[1:] for w in surface.split())])
    for e in out.values():   # links point at main records only, never at itself
        e['links'] = [l for l in dict.fromkeys(main.get(l) or l for l in e['links']) if l in out and l != e['id']]
    return out


def match_key(name): return fold(name)


def fold_in(entries, item, eid, kind):
    """Find the entry `item` (a know or dictionary entry) names, by id, else by its name or a short form."""
    by_name = fold_in.index
    hit = next((e for e in entries.values() if item.get('id') and item['id'] in e.get('_ids', ())), None) if item.get('id') else None
    if hit is None:
        ids = by_name.get(match_key(item.get('name') or item.get('text') or ''), [])
        same_kind = [i for i in ids if entries[i]['kind'] == kind] or ids
        if len(set(same_kind)) == 1: hit = entries[same_kind[0]]
    return hit
fold_in.index = {}


def reindex(entries):
    idx = defaultdict(list)
    for e in entries.values():
        for x in labels(e): idx[match_key(x)].append(e['id'])
    fold_in.index = idx


def from_know(entries, pack):
    reindex(entries)
    for k in pack.get('entries') or []:
        if not isinstance(k, dict) or k.get('scope') == 'private' or k.get('kind') == 'phrase': continue
        kind = KIND_OF.get(k.get('kind'), 'term')
        e = fold_in(entries, k, None, kind)
        if e is None:
            eid = 'know:' + (k.get('id') or fold(k.get('name')))
            if eid in entries: e = entries[eid]
            else:
                e = entries[eid] = blank(eid, kind, k.get('name', ''))
                add_unique(e['short'], [a for a in k.get('aliases', []) if fold(a) != fold(k.get('name'))])
                h = k.get('handles') or {}
                e['phones'] = list(h.get('phone', [])); e['emails'] = list(h.get('email', []))
                e['card'] = bool(k.get('cards_only'))
                for x in labels(e): fold_in.index[match_key(x)].append(eid)
        add_unique(e['short'], [a for a in [k.get('name', '')] + list(k.get('aliases', [])) if fold(a) not in {fold(e['uk']), fold(e['latin'])}])
        add_unique(e['forms'], k.get('forms', []))
        add_unique(e['common'], k.get('common', []), key=str)
        if not e['card'] or not k.get('cards_only'): e['card'] = e['card'] and bool(k.get('cards_only'))
        if 'know' not in e['sources']: e['sources'].append('know')
        for t in k.get('tokens', []):   # a token of a name that is not in its labels (a two-word alias part) stays known
            if fold(t) not in {fold(w) for w in surfaces(e)}: e.setdefault('parts', []).append(t)


def from_words(entries, d):
    """Dictionary words: their mishearings join the entry they spell; an unknown word becomes its own entry."""
    reindex(entries)
    for w in d.get('words') or []:
        w = {'text': w} if isinstance(w, str) else w
        text = (w.get('text') or '').strip()
        if not text: continue
        kind = KIND_OF.get(w.get('kind'), 'term')
        e = fold_in(entries, {'name': text}, None, kind)
        if e is None:
            eid = 'word:' + fold(text)
            e = entries.setdefault(eid, blank(eid, 'term' if w.get('kind') == 'phrase' else kind, text))
            fold_in.index[match_key(text)].append(eid)
        add_unique(e['heard'], w.get('heard', []))
        if 'words' not in e['sources']: e['sources'].append('words')
        e['dictionary'] = True
    for heard, meant in (d.get('loose_heard') or {}).items():
        e = fold_in(entries, {'name': meant}, None, 'term')
        if e is not None: add_unique(e['heard'], [heard])


# ---- forms ----------------------------------------------------------------------------------------------------------

def fill(e):
    """Latin from Ukrainian (or back, for a known first name) and the case forms of an edited or form-less name."""
    import know
    if e['uk'] and not e['latin']:
        e['latin'] = ' '.join(next((v for v in sorted(know.first_variants(t)) if not is_uk(v)), know.transliterate(t) or t)
                              for t in e['uk'].split())
        e.setdefault('auto', []).append('latin')
    if e['latin'] and not e['uk'] and e['kind'] == 'person':
        parts = e['latin'].split()
        uk = next((v for v in know.first_variants(parts[0]) if is_uk(v)), '') if parts else ''
        if uk and len(parts) == 1: e['uk'] = uk; e.setdefault('auto', []).append('uk')
    if e.get('edited') or not e['forms']:
        if e['kind'] == 'person':
            forms = know.person_forms({'name': display(e), 'aliases': [x for x in labels(e) if x != display(e)]})
        else:
            words = e['uk'].split() if e['uk'] else []
            forms = know.case_forms(words[-1]) if len(words) == 1 and words[0][:1].isupper() else set()
        add_unique(e['forms'], sorted(f for f in forms if fold(f) not in {fold(x) for x in labels(e)}))
    e['forms'] = [f for f in e['forms'] if fold(f) not in {fold(x) for x in labels(e)}]


# ---- edits ----------------------------------------------------------------------------------------------------------

def apply_edits(entries, edits):
    """The user's edits, in order. spell: {op, id, uk?, latin?} (the old spelling becomes a mishearing); merge: {op, id, into};
    hide: {op, id, on}; kind: {op, id, kind}. An edit whose entry is gone is skipped. The same rules as
    app/NameRules.swift (golden cases in tests/names_cases.json). -> number applied."""
    n = 0
    for ed in edits or []:
        if not isinstance(ed, dict): continue
        op, eid = ed.get('op'), ed.get('id')
        e = entries.get(eid)
        if e is None: continue
        if op == 'spell':
            for field in ('uk', 'latin'):
                new = ' '.join(str(ed.get(field) or '').split())
                if field in ed and new and new != e[field]:
                    if e[field]: add_unique(e['heard'], [e[field]])
                    e[field] = new
                    e['heard'] = [h for h in e['heard'] if fold(h) != fold(new)]
                    e['auto'] = [a for a in e.get('auto', []) if a != field]
            e['edited'] = True; n += 1
        elif op == 'hide':
            e['hidden'] = bool(ed.get('on', True)); n += 1
        elif op == 'kind':
            new_kind = ed.get('kind')
            if new_kind in KINDS:
                e['kind'] = new_kind
                e['edited'] = True
                n += 1
        elif op == 'merge':
            into = entries.get(ed.get('into'))
            if into is None or into is e: continue
            for x in labels(e): add_unique(into['short'], [x])
            into['short'] = [s for s in into['short'] if fold(s) not in {fold(into['uk']), fold(into['latin'])}]
            for f in ('forms', 'heard', 'phones', 'emails', 'sources', 'links'): add_unique(into[f], e[f], key=str)
            c, o = into['context'], e['context']
            c['lines'] += o['lines']; c['chat_ids'] = add_unique(list(c['chat_ids']), o['chat_ids'], key=str)
            c['chats'] = max(c['chats'], o['chats'], len(c['chat_ids']))
            for app, k in o['apps'].items(): c['apps'][app] = c['apps'].get(app, 0) + k
            c['last_seen'] = max(c['last_seen'], o['last_seen'])
            into['links'] = [l for l in into['links'] if l not in (into['id'], e['id'])]
            del entries[eid]
            for other in entries.values():
                other['links'] = [l for l in dict.fromkeys(into['id'] if l == eid else l for l in other['links']) if l != other['id']]
            n += 1
    return n


# ---- context --------------------------------------------------------------------------------------------------------

def mention_index(entries):
    """Word (folded) -> the one entry it names; words shared by several entries name none (counts stay honest).
    Multi-word labels -> entry as well, so a full name counts even when its parts are shared."""
    single, multi = defaultdict(set), {}
    for e in entries.values():
        if e['hidden']: continue
        for w in surfaces(e):
            if len(w) >= 3: single[fold(w)].add(e['id'])
        for x in labels(e):
            t = tuple(fold(w) for w in toks(x))
            if len(t) >= 2: multi.setdefault(t, set()).add(e['id'])
    return ({w: next(iter(ids)) for w, ids in single.items() if len(ids) == 1},
            {t: next(iter(ids)) for t, ids in multi.items() if len(ids) == 1})


def mentions(text, single, multi, common):
    words = toks(text)
    low = [fold(w) for w in words]
    hits = set()
    for i, w in enumerate(words):
        eid = single.get(low[i])
        if eid and (w[:1].isupper() or low[i] not in common.get(eid, ())): hits.add(eid)
        for n in (2, 3):
            if i + n <= len(low) and tuple(low[i:i + n]) in multi: hits.add(multi[tuple(low[i:i + n])])
    return hits


def count_context(entries, rows=(), chats=None):
    """rows: the user's lines as {t, app, text}; chats: {chat id: [their lines]}. Fills each entry's context."""
    single, multi = mention_index(entries)
    common = {e['id']: set(e['common']) for e in entries.values()}
    for r in rows:
        text = r.get('text') or ''
        if TEST in text: continue
        for eid in mentions(text, single, multi, common):
            c = entries[eid]['context']
            c['lines'] += 1
            app = r.get('app') or ''
            if app: c['apps'][app] = c['apps'].get(app, 0) + 1
            if r.get('t'): c['last_seen'] = max(c['last_seen'], day(r['t']))
    for chat, lines in (chats or {}).items():
        seen = set()
        for line in lines:
            if isinstance(line, str) and TEST not in line: seen |= mentions(line, single, multi, common)
        for eid in seen:
            c = entries[eid]['context']
            c['chats'] += 1
            if len(c['chat_ids']) < CHAT_IDS_KEPT: c['chat_ids'].append(chat)
    for e in entries.values():
        e['context']['apps'] = dict(Counter(e['context']['apps']).most_common(6))


def weight(e):
    """How much the user uses the entry: lines and chats, warmer when seen lately."""
    c = e['context']
    fresh = 0.0
    if c['last_seen']:
        age = max(0.0, (time.time() - time.mktime(time.strptime(c['last_seen'], '%Y-%m-%d'))) / 86400)
        fresh = math.exp(-age / 60)
    return round(c['lines'] + 3 * c['chats'] + 5 * fresh, 3)


# ---- build ----------------------------------------------------------------------------------------------------------

def build_entries(*, entities=None, know=None, words=None, edits=(), rows=(), chats=None):
    """Pure: the stores as loaded -> {id: entry}. No file is read here."""
    entries = from_entities(entities or {})
    from_know(entries, know or {})
    from_words(entries, words or {})
    apply_edits(entries, edits)
    for e in entries.values():
        fill(e)
        if e['kind'] not in KINDS: e['kind'] = 'term'
    count_context(entries, rows, chats)
    for e in entries.values():
        e['weight'] = weight(e)
        e.pop('_ids', None)
        if e.get('parts'): e['parts'] = sorted(set(e['parts']))
    return entries


def ordered(entries):
    return sorted(entries.values(), key=lambda e: (-e['weight'], e['card'], fold(display(e))))


def corpus_rows(data):
    path = data / 'corpus.jsonl'
    rows = []
    try:
        with path.open() as f:
            for line in f:
                try: r = json.loads(line)
                except ValueError: continue
                if isinstance(r, dict) and isinstance(r.get('text'), str): rows.append(r)
        built = path.stat().st_mtime
    except OSError: built = 0
    try:   # what the user typed after the corpus was built
        with (data / 'typed.jsonl').open() as f:
            for line in f:
                try: r = json.loads(line)
                except ValueError: continue
                if isinstance(r, dict) and isinstance(r.get('text'), str) and (r.get('t') or 0) > built: rows.append(r)
    except OSError: pass
    return rows


def chat_map(data):
    d = read_json(data / 'people.json', {})
    chats = d.get('chats') if isinstance(d, dict) else None
    return {k: [x for x in (c.get('mine') or []) if isinstance(x, str)] for k, c in (chats or {}).items() if isinstance(c, dict)}


def build(data=DATA, out=None, now=None, derive_files=True):
    data = Path(data)
    out = Path(out) if out else data / 'names.json'
    entries = build_entries(entities=read_json(data / 'entities.json', {}), know=read_json(data / 'know.json', {}),
                            words=read_json(data / 'words.json', {}), edits=read_json(data / 'names-edits.json', []),
                            rows=corpus_rows(data), chats=chat_map(data))
    store = {'version': 1, 'built': now or time.time(), 'entries': ordered(entries)}
    store['voice'] = voice_hint(store)
    atomic(out, json.dumps(store, ensure_ascii=False, indent=0) + '\n')
    if derive_files: derive(data, store)
    return store


# ---- derived files and readers --------------------------------------------------------------------------------------

def known_words(store):
    """Autocorrect's known words: every word of every shown entry that is not a contact card only."""
    out = set()
    for e in store.get('entries', []):
        if e.get('hidden') or e.get('card'): continue
        out.update(surfaces(e)); out.update(e.get('parts', []))
    return sorted(out)


def voice_rank(store):
    """folded spelling -> rank (0 = most used), for ordering the dictionary's terms."""
    rank = {}
    for i, e in enumerate(store.get('entries', [])):
        if e.get('hidden'): continue
        for x in labels(e): rank.setdefault(fold(x), i)
    return rank


def words_view(d, store):
    """The dictionary in the voice engine's shape, with the names reference folded in: terms in order of use, the user's spelling
    fixes as terms, their old spellings as mishearings; hidden names out. Used by dictionary.save."""
    rank = voice_rank(store) if store else {}
    entries = store.get('entries', []) if store else []
    hidden = {fold(x) for e in entries if e.get('hidden') for x in labels(e)}
    terms = [t for t in d.get('terms', []) if fold(t) not in hidden]
    for e in entries:   # a spelling the user fixed on the Names page is a term (it was wrong once, so it can be misheard)
        if e.get('edited') and not e.get('hidden'):
            add_unique(terms, [x for x in (e.get('uk'), e.get('latin')) if x and x not in e.get('auto', [])])
    pos = {fold(t): i for i, t in enumerate(terms)}
    terms.sort(key=lambda t: (rank.get(fold(t), len(rank) + pos[fold(t)]), pos[fold(t)]))
    heard = {h: m for h, m in d.get('heard', {}).items() if fold(m) not in hidden}
    for e in entries:
        if e.get('hidden'): continue
        for h in e.get('heard', []):
            if fold(h) not in {fold(x) for x in labels(e)}: heard.setdefault(h, display(e))
    return terms, heard


def derive(data=DATA, store=None):
    data = Path(data)
    store = store if store is not None else read_json(data / 'names.json', None)
    if not store: return {}
    changed = False
    for e in store.get('entries', []):   # an edit made in the app: case forms for its new spelling
        if e.get('edited') and not e.get('formed'):
            e['forms'] = []; fill(e); e['formed'] = True; changed = True
    if changed or store.get('voice') != voice_hint(store):
        store['voice'] = voice_hint(store); changed = True
    if changed: atomic(data / 'names.json', json.dumps(store, ensure_ascii=False, indent=0) + '\n')
    kw = known_words(store)
    atomic(data / 'known-words.txt', '\n'.join(kw) + '\n')
    n_terms = 0
    if (data / 'words.json').exists():
        import dictionary
        d = dictionary.load(data / 'words.json')
        n_terms = len(dictionary.save(d, data / 'words.json', store=store)['terms'])
    return {'known_words': len(kw), 'terms': n_terms}


def voice_hint(store, n=VOICE_TERMS):
    """Whisper's glossary: the names the user uses most, as spelled (never a guessed transliteration or an ordinary word)."""
    out = []
    for e in store.get('entries', []):
        if e.get('hidden') or (e.get('card') and not e['context']['lines']) or not e['context']['lines']: continue
        add_unique(out, [e[f] for f in ('latin', 'uk') if e.get(f) and f not in e.get('auto', []) and len(e[f]) >= 3
                         and not set(fold(w) for w in toks(e[f])) <= set(e.get('common', []))])
        if len(out) >= n: break
    return out[:n]


class Pack:
    """The names reference as the word finisher and booster read it (the same interface as know.Pack). Re-read when the
    file changes; a broken file keeps the last good one."""
    NAME_KINDS = ('person', 'project', 'company', 'place', 'term')
    FLOOR = 0.06   # a name's own use against the other words the user writes with the same letters (know.py: 0.03)
    START_FLOOR = 0.3    # the same at a sentence start, where a capital says nothing (held-out lines, 2026-11-15)

    def __init__(self, path=None):
        self.path = Path(path) if path is not None and str(path) != 'none' else None
        self.stamp = None
        self.entries, self.by_prefix = [], {}
        self.offered = 0

    def reload(self):
        if self.path is None: return
        try:
            st = self.path.stat(); stamp = (st.st_mtime_ns, st.st_size)
            if stamp == self.stamp: return
            self.stamp = stamp
            self.load(json.loads(self.path.read_text()))
        except FileNotFoundError: self.entries, self.stamp = [], None
        except (OSError, ValueError, KeyError, TypeError, AttributeError): pass

    def load(self, store):
        entries = [e for e in store['entries'] if isinstance(e, dict) and not e.get('hidden')]
        forms = defaultdict(float)   # capitalised word -> weight of the entries it names
        for e in entries:
            if e.get('card') or e.get('kind') not in self.NAME_KINDS: continue
            common = set(e.get('common', []))
            for w in surfaces(e) + list(e.get('parts', [])):
                if w[:1].isupper() and fold(w) not in common: forms[w] += 1 + e.get('weight', 0)
        self.entries = entries
        self.forms = dict(forms)
        self.by_prefix = defaultdict(list)
        for w in self.forms:
            for k in range(2, min(len(w), 4) + 1): self.by_prefix[w[:k].casefold()].append(w)
        return self

    def snapshot(self):
        self.reload()
        view = Pack(); view.entries, view.stamp = self.entries, self.stamp
        view.forms, view.by_prefix = getattr(self, 'forms', {}), self.by_prefix
        return view

    def candidates(self, typed):
        pool = self.by_prefix.get(typed[:4].casefold(), [])
        return [w for w in pool if w.startswith(typed) and len(w) > len(typed)]

    def finish(self, before, own_counts=None, prefix_totals=None):
        """The rest of a name after 2+ letters (its first one capital), in any case form. A form the user wrote counts by their
        use of it; one the user never wrote counts by its entry's use, at a fifth. The leader needs 60% of the names that fit
        and twice the next; if the user writes other words with these letters, the name needs its share of them too."""
        self.reload()
        m = HALF.search(before or '')
        if not m or len(m.group()) < 2 or not m.group()[0].isupper(): return ''
        typed = m.group()
        own = own_counts or {}
        cands = self.candidates(typed)
        if not cands or any(w == typed for w in self.forms if w.casefold() == typed.casefold()): return ''
        scored = Counter()
        for w in cands: scored[w] = own.get(w.casefold(), 0) + 0.2 * self.forms[w]
        (top, s1), *rest = scored.most_common(2)
        s2 = rest[0][1] if rest else 0
        total = sum(scored.values())
        if s1 <= 0 or s1 < 0.6 * total or (rest and s1 < 2 * s2): return ''
        used = own.get(top.casefold(), 0)
        competing = (prefix_totals or {}).get(typed.casefold(), 0) - sum(own.get(w.casefold(), 0) for w in cands)
        if used < 1 and (len(typed) < 3 or competing >= 2): return ''
        start = not re.search(r"[^\W_]", re.split(r"[.!?\n]", before[:m.start()])[-1])
        if competing >= 2 and used < (self.START_FLOOR if start else self.FLOOR) * competing: return ''
        return top[len(typed):]

    def targets(self, before, context='', title=''):
        """Names on screen that fit the letters typed: the booster's share (as know.Pack.targets)."""
        self.reload()
        m = HALF.search(before or '')
        if not m or len(m.group()) < 2 or not m.group()[0].isupper(): return []
        typed = m.group()
        screen = set(toks(context + '\n' + title))
        weights = {}
        for w in self.candidates(typed):
            if w in screen: weights[w[len(typed):]] = max(weights.get(w[len(typed):], 0), max(.25, self.forms[w]))
        total = sum(weights.values()) or 1
        return [(w, n / total) for w, n in sorted(weights.items())]

    def people(self, query):
        self.reload(); q = fold(query.strip().lstrip(';'))
        if len(q) < 2: return []
        hits = [e for e in self.entries if e['kind'] == 'person' and (e.get('phones') or e.get('emails'))
                and any(fold(w).startswith(q) for w in labels(e) + list(e.get('forms', [])))]
        return [{'name': display(e), 'aliases': e['short'], 'handles': {k: v for k, v in (('phone', e['phones']), ('email', e['emails'])) if v},
                 'heat': e.get('weight', 0)} for e in sorted(hits, key=lambda e: (-e.get('weight', 0), display(e)))[:30]]

    def stats(self):
        self.reload()
        return {'entries': len(self.entries), 'offered': self.offered}


def stats(store):
    es = store.get('entries', [])
    return {'entries': len(es), 'kinds': dict(Counter(e['kind'] for e in es)), 'cards': sum(e['card'] for e in es),
            'hidden': sum(e['hidden'] for e in es), 'with_forms': sum(1 for e in es if e['forms']),
            'forms': sum(len(e['forms']) for e in es), 'with_heard': sum(1 for e in es if e['heard']),
            'with_phone': sum(1 for e in es if e['phones']), 'with_email': sum(1 for e in es if e['emails']),
            'with_links': sum(1 for e in es if e['links']), 'mentioned': sum(1 for e in es if e['context']['lines']),
            'in_chats': sum(1 for e in es if e['context']['chats'])}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['build', 'derive', 'stats'])
    ap.add_argument('--data', type=Path, default=DATA)
    a = ap.parse_args()
    t0 = time.time()
    if a.command == 'build':
        store = build(a.data)
        print(json.dumps({**stats(store), 'ms': int((time.time() - t0) * 1000)}))
    elif a.command == 'derive':
        print(json.dumps(derive(a.data)))
    else:
        print(json.dumps(stats(read_json(a.data / 'names.json', {'entries': []}))))
