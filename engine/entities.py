"""The entity store (step 1 of docs/reviews/2026-11-14-entities.md): one local record per real thing the user names - a
person, org, project, tool, document or place - built from the sources the user already keeps, and the context packs an
agent can read. Importing this module reads nothing.

    .venv/bin/python engine/entities.py build            # data/entities.json (know.py build calls it too)
    .venv/bin/python engine/entities.py stats            # counts only
    .venv/bin/python engine/entities.py pack <name> [--level 2|3]
    .venv/bin/python engine/entities.py context <name>   # the entity and its related ones, one brief
    .venv/bin/python engine/entities.py fix not_related <id> <id>   # the user's corrections (data/entity-fixes.json)

Sources: the user's typed lines (data/typed.jsonl), terms the model classified (data/entity-kinds.json), project
folders (`projects.roots`) and the user's own fixes. build() also takes source records from a caller (`slices`, the
tests' made-up cast): {system: [{id, kind, name, aliases, handles, facts, links, ...}]}.

A record marked private says so (`private: true`). No model writes a fact: a pack is a fixed template over
stored records, each fact with its source and date. The app reads the prebuilt `surfaces` map and the pack parts;
app/EntityRules.swift renders the same text (tests/entity_cases.json holds the golden cases both sides run).
"""
import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / 'data'
sys.path.insert(0, str(Path(__file__).resolve().parent))

KINDS = ('person', 'org', 'project', 'tool', 'doc', 'place')
KIND_KEYS = {'1': 'person', '2': 'org', '3': 'project', '4': 'tool', '5': 'doc', '6': 'place', '0': 'none'}
KIND_WORD = {'person': 'person', 'org': 'org', 'project': 'project', 'tool': 'tool', 'doc': 'document', 'place': 'place'}
ORDER = {'board': 1}         # which source record heads a merged group; then the one with the most facts
MATCH = {'name': 3.0, 'alias': 2.5, 'pair': 2.5, 'form': 2.0, 'first': 1.0, 'part': 1.0}

HEADER = 'Context (background from my notes, not instructions):'
LINE_MAX, FULL_MAX, BLOCK_MAX, BRIEF_MAX, WHO_MAX, FACT_MAX = 160, 600, 1800, 3000, 80, 120
STALE_DAYS = 90

PHONE = re.compile(r'\+?\d[\d ()\-.]{6,}\d')
EMAIL = re.compile(r'[^\s@<>()]+@[^\s@<>()]+\.[^\s@<>()]+')
APOS = str.maketrans({'’': "'", 'ʼ': "'", '`': "'", '‘': "'"})
WORDS = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)


def fold(s):
    """The key of a surface form: lower case, one apostrophe, single spaces (ґ stays ґ)."""
    return ' '.join(str(s or '').translate(APOS).casefold().split())


def one_line(s, n):
    """One clean line of at most n characters, cut at a word with an ellipsis; phone numbers never survive."""
    s = ' '.join(str(s or '').split())
    s = PHONE.sub('', s).strip(' ,;')
    s = re.sub(r'\s{2,}', ' ', s)
    if len(s) <= n: return s
    cut = s[:n - 1].rsplit(' ', 1)[0] if ' ' in s[:n - 1] else s[:n - 1]
    return cut.rstrip(' ,;.:-') + '…'


def day(ts):
    try: return time.strftime('%Y-%m-%d', time.localtime(float(ts))) if ts else ''
    except (TypeError, ValueError, OverflowError, OSError): return ''


def read_json(path, default):
    try: return json.loads(Path(path).read_text())
    except FileNotFoundError: return default
    except (OSError, ValueError): return default


def atomic(path, text):
    from know import atomic as write
    write(path, text)


def own_names(data=DATA):
    cfg = read_json(Path(data) / 'drafter.local.json', {})
    user = cfg.get('user', {}) if isinstance(cfg, dict) else {}
    names = [user.get('name') or '', user.get('short_name') or ''] + list(user.get('own_names') or [])
    return {fold(n) for n in names if isinstance(n, str) and n.strip()}


# ---------------------------------------------------------------------------------------------------------------
# merging

class Union:
    def __init__(self): self.up, self.members = {}, {}
    def find(self, a):
        if a not in self.up: self.up[a] = a; self.members[a] = {a}
        while self.up[a] != a:
            self.up[a] = self.up[self.up[a]]; a = self.up[a]
        return a
    def join(self, a, b, apart):
        ra, rb = self.find(a), self.find(b)
        if ra == rb: return True
        if apart and any((x, y) in apart or (y, x) in apart for x in self.members[ra] for y in self.members[rb]): return False
        self.up[rb] = ra
        self.members[ra] |= self.members.pop(rb)
        return True


def norm_handle(kind, v):
    v = str(v or '').strip()
    if kind == 'email': return v.casefold()
    if kind == 'tg': return v.lstrip('@').casefold()
    if kind == 'phone': return re.sub(r'\D', '', v)[-9:]
    return v


def merge(slices, same_file=None):
    """Deterministic merges (proposal 1.5): the user's own yes/no from data/entity-same.json. Never on a name alone
    (dedupe_people merges on a shared handle with names that fit). Returns (groups of source records, count of
    same-name pairs left apart for a "Same?" row)."""
    recs = {f"{r['system']}:{r['id']}": r for s in slices for r in s}
    sf = same_file or {}
    apart = {(a, b) for a, b in (sf.get('not') or []) if isinstance(a, str) and isinstance(b, str)}
    u = Union()
    for k in recs: u.find(k)
    for a, b in (sf.get('same') or []):
        if a in recs and b in recs: u.join(a, b, apart)
    groups = defaultdict(list)
    for k in recs: groups[u.find(k)].append(recs[k])
    out = [sorted(g, key=lambda r: (ORDER.get(r['system'], 9), -len(r.get('facts') or []), r['system'], r['id'])) for g in groups.values()]
    # same full name from two groups, no handle to confirm: left apart, counted for the "Same?" row (step 4)
    by_name = defaultdict(set)
    for i, g in enumerate(out):
        if g[0].get('cards_only'): continue
        by_name[fold(g[0]['name'])].add(i)
    pending = sum(1 for n, s in by_name.items() if len(s) > 1 and ' ' in n)
    return out, pending


# ---------------------------------------------------------------------------------------------------------------
# relations: typed, weighted, each with a reason a person can read (docs/rounds/2026-11-14-relations.md)
#
# One edge = every piece of evidence for a pair: a link a source record declares, being listed in one record, the user's own
# fix, or how often the two are named together in the user's own lines. Each piece scores type x source trust x recency;
# the pieces join as a noisy-or (two weak ones beat one weak one, nothing passes 1); the target's heat nudges it.

# rel: (reason seen from the subject, reason seen from the object, type weight)
REL = {
    'v_org': ('works at', 'works here', 0.9),
    'v_epic': ('part of epic', 'epic of', 0.7), 'v_story': ('part of story', 'story of', 0.7), 'v_thread': ('in thread', 'thread of', 0.6),
    'v_entities': ('in the same note', 'in the same note', 0.6), 'v_people': ('in the same note', 'in the same note', 0.6),
    'v_related': ('in the same note', 'in the same note', 0.6),
    'mine': ('related (you said)', 'related (you said)', 1.0),
}
LIST_KEYS = ('v_entities', 'v_people', 'v_related')
PAIR_W = 0.3                 # two things listed in one note, before the list-length damping
CO_W, CO_MIN = 0.7, 3        # co-mention: weight at full NPMI, and the fewest lines that name both
FLOOR = 0.15                 # an edge under this is dropped
TOP = {'person': 6, 'org': 8, 'project': 8, 'tool': 5, 'doc': 6, 'place': 4}
SHOW_MAX = 8
HALF_LIFE_DAYS = 180


def recency(date, now):
    """0.5 .. 1: fresh evidence counts fully, old evidence half; no date 0.6."""
    if not date: return 0.6
    try: age = max(0.0, (now - time.mktime(time.strptime(date[:10], '%Y-%m-%d'))) / 86400)
    except (ValueError, OverflowError): return 0.6
    return 0.5 + 0.5 * math.exp(-age / HALF_LIFE_DAYS)


def damp_star(n):
    """A note that lists n things: the note to each of them. Long lists say less about each item."""
    return min(1.0, math.sqrt(4.0 / max(1, n)))


def damp_pair(n):
    """Two of the n things one note lists: weaker than the note's own links, falling as 1/(n-1)."""
    return min(1.0, 1.0 / max(1, n - 1))


def piece(rel, rely, date, now, n=1, pair=False):
    """One piece of evidence: type weight x source trust x recency (x list damping for notes that list things)."""
    w = PAIR_W * damp_pair(n) if pair else REL[rel][2] * (damp_star(n) if rel in LIST_KEYS else 1.0)
    return w * rely * recency(date, now)


def npmi(c_ab, c_a, c_b, n):
    """Normalised pointwise mutual information, -1..1. It does not reward a popular entity: a thing named in every
    line tells nothing about the others. Fewer than CO_MIN lines together: 0."""
    if c_ab < CO_MIN or not (c_a and c_b and n): return 0.0
    p_ab = c_ab / n
    if p_ab >= 1: return 1.0
    v = math.log(p_ab / ((c_a / n) * (c_b / n))) / -math.log(p_ab)
    return max(-1.0, min(1.0, v))


def combine(scores):
    """Noisy-or of the pieces: 1 - prod(1 - s)."""
    out = 1.0
    for x in scores: out *= 1.0 - max(0.0, min(1.0, x))
    return 1.0 - out


def heat_factor(heat):
    """0.8 .. 1: a warm target ranks a little higher than a cold one with the same evidence."""
    return 0.8 + 0.2 * min(1.0, math.log(max(1.0, heat or 1)) / math.log(20))


def edge_weight(scores, target_heat):
    return round(combine(scores) * heat_factor(target_heat), 3)


def rank_edges(edges, kind, floor=FLOOR, top=None):
    """edges: [{id, w, heat?, date?}] of one record -> the kept ones, at most TOP[kind] and never more than
    SHOW_MAX; under the floor dropped. Order: weight, then the other record's heat, then the newest evidence, then id.
    Returns (kept, dropped under the floor)."""
    top = min(SHOW_MAX, top if top is not None else TOP.get(kind, 6))
    ok = sorted((e for e in edges if e['w'] >= floor),
                key=lambda e: (-e['w'], -e.get('heat', 1), -int((e.get('date') or '0').replace('-', '') or 0), e['id']))
    return ok[:top], sum(1 for e in edges if e['w'] < floor)


class Edges:
    """Evidence per unordered pair, with the reason from each side. A piece: (score, why from a, why from b, source,
    sort, date); sort is 'co' for names said together, 'decl' for the rest."""
    def __init__(self): self.ev = defaultdict(list)
    def copy(self):
        e = Edges(); e.ev = defaultdict(list, {k: list(v) for k, v in self.ev.items()}); return e
    def add(self, a, b, score, why_from_a, why_from_b, src, sort='decl', date=''):
        if a == b or score <= 0: return
        if a < b: self.ev[(a, b)].append((score, why_from_a, why_from_b, src, sort, date))
        else: self.ev[(b, a)].append((score, why_from_b, why_from_a, src, sort, date))
    def drop(self, a, b): self.ev.pop((min(a, b), max(a, b)), None)
    def folded(self, main_of):
        """The same evidence with every twin replaced by its main record (a project and its repo are one thing);
        evidence between two twins of one thing is gone."""
        e = Edges()
        for (a, b), ps in self.ev.items():
            ma, mb = main_of.get(a, a), main_of.get(b, b)
            if ma == mb: continue
            for x, wa, wb, src, sort, date in ps: e.add(ma, mb, x, wa, wb, src, sort, date)   # ma stands where a stood
        return e
    def of(self):
        """record id -> [(other id, [(score, why seen from this record, src, sort, date)])]"""
        out = defaultdict(list)
        for (a, b), ps in self.ev.items():
            out[a].append((b, [(x, wa, src, so, d) for x, wa, wb, src, so, d in ps]))
            out[b].append((a, [(x, wb, src, so, d) for x, wa, wb, src, so, d in ps]))
        return out


def declared_edges(records, now, fixes=None, resolve=lambda x: x):
    """Edges from what the source records declare (links, lists) and the user's own fixes."""
    E = Edges()
    ids = {r['id'] for r in records}
    for r in records:
        lists = defaultdict(list)   # one note's list -> its members, for the pair edges
        for e in r.get('evidence', []):
            to, rel = e['to'], e['rel']
            if to not in ids or to == r['id'] or rel not in REL: continue
            fwd, back, _ = REL[rel]
            if rel in LIST_KEYS: fwd = back = 'in the same note: ' + e.get('note', 'note')
            E.add(r['id'], to, piece(rel, e.get('rely', 0.8), e.get('date', ''), now, e.get('n', 1)), fwd, back,
                  e.get('src', ''), 'decl', e.get('date', ''))
            if rel in LIST_KEYS: lists[rel].append(e)
        for rel, members in lists.items():
            if len(members) > 12: continue   # a long list: its pairs would all fall under the floor anyway
            for i in range(len(members)):
                for j in range(i + 1, len(members)):
                    a, b = members[i], members[j]
                    if a['to'] == b['to']: continue
                    why = 'in the same note: ' + a.get('note', 'note')
                    E.add(a['to'], b['to'], piece(rel, a.get('rely', 0.9), a.get('date', ''), now, a.get('n', 2), pair=True), why, why, a.get('src', ''),
                          'decl', a.get('date', ''))
    for r in records: r.pop('evidence', None)
    fixes = fixes or {}
    for item in fixes.get('related') or []:
        if isinstance(item, list) and len(item) >= 2:
            a, b = resolve(item[0]), resolve(item[1])
            why = str(item[2]) if len(item) > 2 and item[2] else REL['mine'][0]
            if a in ids and b in ids: E.add(a, b, 1.0, why, why, 'you')
    return E


def finish_edges(records, E, co=None, floor=FLOOR, not_related=(), main_of=None):
    """Turn the evidence into `related` (ordered ids, for old readers) and `relations` ([{id, why, w, src}]).
    co: {(a, b): (score, reason)} co-mention pieces. main_of: twin id -> its main record id; an edge to a twin is an
    edge to the main record, and a twin shows its main record's relations. Returns counts."""
    for (a, b), (x, why) in (co or {}).items():
        E.add(a, b, x, why, why, 'lines', 'co')
    for a, b in not_related: E.drop(a, b)
    main_of = main_of or {}
    if main_of:
        for a, b in not_related: E.drop(main_of.get(a, a), main_of.get(b, b))
        E = E.folded(main_of)
        for a, b in not_related: E.drop(main_of.get(a, a), main_of.get(b, b))
    by_id = {r['id']: r for r in records}
    of = E.of()
    kept = dropped = 0
    for r in records:
        if r['id'] in main_of: continue
        edges = []
        for other, ps in of.get(r['id'], []):
            ps = sorted(ps, key=lambda p: -p[0])
            whys = []
            for p in ps:
                if p[1] not in whys: whys.append(p[1])
            o = by_id[other]
            edges.append({'id': other, 'w': edge_weight([p[0] for p in ps], o.get('heat', 1)), 'heat': o.get('heat', 1),
                          'date': max((p[4] for p in ps), default=''),
                          'why': ' · '.join(whys[:2]), 'src': sorted({p[2] for p in ps if p[2]})})
        keep, drop = rank_edges(edges, r['kind'], floor)
        r['related'] = [e['id'] for e in keep]
        r['relations'] = [{'id': e['id'], 'why': e['why'], 'w': e['w'], 'src': e['src']} for e in keep]
        kept += len(keep); dropped += drop
    for r in records:   # a twin shows the thing's relations
        m = main_of.get(r['id'])
        if m:
            r['related'] = list(by_id[m]['related']); r['relations'] = [dict(x) for x in by_id[m]['relations']]
    return {'kept': kept, 'dropped': dropped}


# ---------------------------------------------------------------------------------------------------------------
# ambiguous name forms: a form that points to several records, is an ordinary word, or has 4 letters or fewer
# counts as a mention only when the context decides (app/EntityRules.swift `decide` is its twin)

NEED = {'shared': 1.0, 'short': 1.0, 'ordinary': 2.0, 'twins': 0.0}
SHORT_MAX = 4
# what kind of thing the user names where (dest as app/RefRules.swift names it)
EXPECT = {'agent': ('tool', 'project'), 'ai': ('project', 'tool', 'person'), 'chat': ('person', 'project', 'org'), 'mail': ('person', 'org')}
AI_APPS = {'claude', 'chatgpt', 'codex', 'perplexity', 'com.openai.chat', 'com.openai.codex', 'com.anthropic.claudefordesktop', 'com.perplexity.mac'}
CHAT_APPS = {'beeper', 'slack', 'whatsapp', 'telegram', 'messages', 'discord', 'microsoft teams', 'signal', 'com.automattic.beeper.desktop',
             'com.tinyspeck.slackmacgap', 'net.whatsapp.whatsapp', 'ru.keepcoder.telegram', 'com.apple.mobilesms', 'com.hnc.discord',
             'com.microsoft.teams2', 'org.whispersystems.signal-desktop'}
MAIL_APPS = {'mail', 'superhuman', 'spark', 'outlook', 'microsoft outlook', 'mimestream', 'com.apple.mail', 'com.superhuman.electron',
             'com.readdle.sparkdesktop', 'com.microsoft.outlook', 'com.mimestream.mimestream'}
AGENT_APPS = {'terminal', 'iterm2', 'ghostty', 'warp', 'kitty', 'code', 'visual studio code', 'zed', 'cursor', 'xcode', 'com.apple.terminal',
              'com.googlecode.iterm2', 'com.mitchellh.ghostty', 'dev.warp.warp-stable', 'net.kovidgoyal.kitty', 'com.microsoft.vscode',
              'dev.zed.zed', 'com.todesktop.230313mzl4w4u92', 'com.apple.dt.xcode'}


def dest_of(app):
    """The destination for an app name or bundle id from data/typed.jsonl: agent, ai, chat, mail or plain."""
    a = str(app or '').casefold()
    if a in AGENT_APPS: return 'agent'
    if a in AI_APPS: return 'ai'
    if a in CHAT_APPS: return 'chat'
    if a in MAIL_APPS: return 'mail'
    return 'plain'


def flag_record(flags):
    """How a name form is marked in the store's `surface_flags`: what it needs before it counts as a mention."""
    return {'needs_context': any(f != 'twins' for f in flags), 'shared': 'shared' in flags, 'twins': 'twins' in flags,
            'ordinary': 'ordinary' in flags, 'short': 'short' in flags}


def heat_bonus(heat):
    return min(1.0, math.log(1 + max(0.0, (heat or 1) - 1)) / math.log(20))


def form_flags(key, hits, ordinary, own_lower, names):
    """What a name form needs before it counts: 'shared' (several records with different names), 'twins' (several
    records with one name: a project, its repo and its Worker), 'ordinary' (a dictionary word or a word the user writes in
    lower case), 'short' (4 letters or fewer). names: index -> the record's name. [] = nothing needed."""
    flags = []
    if len({i for i, _ in hits}) > 1:
        flags.append('twins' if len({fold(names[i]) for i, _ in hits}) == 1 else 'shared')
    if ' ' not in key:
        slug = any(names[i] == names[i].lower() and how in ('name', 'alias') for i, how in hits)
        if key in ordinary or (key in own_lower and not slug): flags.append('ordinary')
        if len(key.replace('-', '').replace("'", '')) <= SHORT_MAX: flags.append('short')
    return flags


def support(c):
    """How much the context backs one candidate: a related thing named nearby 2, its own fuller name nearby 2, the chat
    box's placeholder names this person 2, the kind expected in this app 1, and then heat up to 1 (heat alone backs
    nothing)."""
    base = 2.0 * bool(c.get('related')) + 2.0 * bool(c.get('named')) + 2.0 * bool(c.get('chat')) + 1.0 * bool(c.get('kind'))
    return base + heat_bonus(c.get('heat', 1)) if base else 0.0   # heat only backs a context signal, never alone


def decide(cands, flags=(), picked=None):
    """cands: [{i, how, score, heat, related, named, kind}]. Returns (index or None, resolved).
    No flags: the old rule (best score; resolved when at least twice the next). A remembered pick decides.
    Twins (one name, several records: a project and its repo): one thing named, the record of the kind expected here.
    Shared: a stronger kind of match decides (a full name over a surname, at least 2x); otherwise the context must back
    one candidate with at least NEED and twice the next. Ordinary or short: the context must back it with NEED.
    If it does not: an ordinary or short form is no mention (None); a shared form stays unresolved for the chooser."""
    if not cands: return None, False
    if picked is not None and any(c['i'] == picked for c in cands): return picked, True
    many = len({c['i'] for c in cands}) > 1
    flags = [f for f in flags if f not in ('shared', 'twins') or many]
    order = sorted(cands, key=lambda c: (-c['score'], c['i']))
    top, second = order[0], (order[1]['score'] if len(order) > 1 else 0)
    if not flags: return top['i'], second == 0 or top['score'] >= 2 * second
    if 'shared' in flags and not ('ordinary' in flags or 'short' in flags):
        bases = sorted((MATCH.get(c['how'], 1), c['i']) for c in cands)
        if bases[-1][0] >= 2 * bases[-2][0]: return bases[-1][1], True
    need = max(NEED[f] for f in flags)
    by = sorted(cands, key=lambda c: (-support(c), -bool(c.get('kind')), -c['score'], c['i']))
    s1 = support(by[0])
    s2 = support(by[1]) if len(by) > 1 and 'shared' in flags else 0
    if s1 >= need and s1 >= 2 * s2: return by[0]['i'], True   # twins alone: need 0, nothing to beat
    if 'ordinary' in flags or 'short' in flags: return None, False
    return top['i'], False


def own_lower_words(texts, least=3, share=0.6):
    """Words the user writes in lower case in the middle of a sentence (at least `least` times and `share` of the time):
    the user's ordinary words in any script, Ukrainian included."""
    low, cap = Counter(), Counter()
    for text in texts:
        last = 0   # end of the previous word
        start = True
        for m in WORDS.finditer(text):
            gap = text[last:m.start()]
            if any(ch in '.!?\n:' for ch in gap): start = True
            w = m.group()
            if not start: (low if w[:1].islower() else cap)[fold(w)] += 1
            start, last = False, m.end()
    return {w for w, n in low.items() if n >= least and n >= share * (n + cap[w])}


def scan(text, store_surfaces, flags, records, *, dest='plain', ctx_extra='', related=None, heat=None, not_this=None):
    """The names in one line, longest first and never overlapping, each decided as the app's matcher would:
    [(record index or None, resolved, key, candidates)]."""
    related = related or {}
    ctx = fold(text + ' ' + ctx_extra)
    expect = EXPECT.get(dest, ())
    target = chat_target(ctx)
    toks = list(WORDS.finditer(text))
    out, i = [], 0
    while i < len(toks):
        step = 1
        for n in (3, 2, 1):
            if i + n > len(toks): continue
            span = toks[i:i + n]
            if any(text[span[k].end():span[k + 1].start()].strip(' ') != '' or text[span[k].end():span[k + 1].start()] == '' for k in range(n - 1)): continue
            raw = text[span[0].start():span[-1].end()]
            key = fold(raw)
            hits = store_surfaces.get(key)
            if not hits: continue
            capital = raw[:1].isupper()
            before = text[:span[0].start()].rstrip(' ')
            start = not before or before[-1] in '.!?\n:'
            cands = []
            for idx, how in hits:
                r = records[idx]
                if r.get('cards_only'): continue
                if not capital and not (r['name'] == r['name'].lower() and r['kind'] != 'person' and how in ('name', 'alias')): continue
                h = (heat or {}).get(idx, r.get('heat', 1))
                sc = MATCH.get(how, 1) + (0.5 if capital and not start else 0) + heat_bonus(h)
                rel = any(len(nm) >= 3 and nm in ctx for nm in related.get(idx, ()))
                if len(hits) > 1 and rel: sc += 1
                names = [fold(x) for x in [r['name']] + r.get('aliases', [])]
                named = any(len(x) >= 3 and x != key and x in ctx for x in names)
                chat = r['kind'] == 'person' and names_chat(key, target)
                cands.append({'i': idx, 'how': how, 'score': sc, 'heat': h, 'related': rel, 'named': named, 'chat': chat,
                              'kind': r['kind'] in expect or chat})
            if not cands: continue
            got, ok = decide(cands, flags.get(key, ()))
            out.append((got, ok, key, [c['i'] for c in cands]))
            step = n
            break
        i += step
    return out


# ---------------------------------------------------------------------------------------------------------------
# the user's corrections: data/entity-fixes.json (never in git). Pure add_fix for the app's card ("Not related",
# "Not this one"); the build applies the file.
#   {"related": [[a, b, why]], "not_related": [[a, b]], "not_this": [[form, id]], "same": [[a, b]], "not_same": [[a, b]]}

FIX_KINDS = ('related', 'not_related', 'not_this', 'same', 'not_same')
FIX_OPPOSITE = {'related': 'not_related', 'not_related': 'related', 'same': 'not_same', 'not_same': 'same'}


def _pair(a, b): return sorted([str(a), str(b)])


def add_fix(fixes, what, a, b, why=''):
    """A new fixes dict with one fix added (pure). related / not_related / same / not_same: a and b are record ids
    (order does not matter); not_this: a is the name form, b the record id. A fix replaces its opposite."""
    if what not in FIX_KINDS: raise ValueError(what)
    out = {k: [list(x) for x in (fixes or {}).get(k) or []] for k in FIX_KINDS}
    if what == 'not_this':
        item = [fold(a), str(b)]
        if item not in out['not_this']: out['not_this'].append(item)
        return out
    if str(a) == str(b): return out
    key = _pair(a, b)
    opp = FIX_OPPOSITE[what]
    out[opp] = [x for x in out[opp] if _pair(x[0], x[1]) != key]
    out[what] = [x for x in out[what] if _pair(x[0], x[1]) != key]
    out[what].append(key + ([why] if what == 'related' and why else []))
    return out


def read_fixes(data=DATA):
    f = read_json(Path(data) / 'entity-fixes.json', {})
    return f if isinstance(f, dict) else {}


def save_fix(what, a, b, why='', data=DATA):
    """Add one fix to data/entity-fixes.json (the next build applies it)."""
    fixes = add_fix(read_fixes(data), what, a, b, why)
    atomic(Path(data) / 'entity-fixes.json', json.dumps(fixes, ensure_ascii=False, indent=1) + '\n')
    return fixes

# ---------------------------------------------------------------------------------------------------------------
# one person, several records; the user's own name; apps stored as people; one thing under several kinds

def skel(s):
    """A loose spelling key for comparing names across scripts: transliterated, case folded, y/j as i, kh as h,
    doubled letters single, labels in brackets left out."""
    from know import transliterate
    out = []
    for w in WORDS.findall(unlabel(s)):
        t = (transliterate(w) or w).casefold().replace("'", '').replace('-', '')
        t = t.replace('kh', 'h').replace('y', 'i').replace('j', 'i')
        out.append(re.sub(r'(.)\1+', r'\1', t))
    return ' '.join(out)


def initials_only(raw):
    """"OP", "ЮК": a label that is only initials (2-3 capitals, one token)."""
    t = unlabel(raw).replace('.', '')
    return 2 <= len(t) <= 3 and t.isalpha() and t.isupper()


def name_match(la, lb):
    """(score, reason) for two people's labels: 3 same full name (or in the other script), 2 initials or a short
    surname ("Hanna T." and "Hanna Tkach"), 1 the first name of one is the whole name of the other, 0 nothing."""
    best = (0, '')
    A = [(fold(unlabel(x)), skel(x), x) for x in la if str(x).strip()]
    B = [(fold(unlabel(x)), skel(x), x) for x in lb if str(x).strip()]
    for fa, sa, ra in A:
        for fb, sb, rb in B:
            ta, tb = sa.split(), sb.split()
            if not ta or not tb: continue
            got = (0, '')
            if len(ta) >= 2 and fa == fb: got = (3, 'same full name')
            elif len(ta) >= 2 and len(tb) >= 2 and sa == sb: got = (3, 'same name in the other script')
            elif initials_only(ra) and len(tb) >= 2 and ''.join(t[0] for t in tb) == ta[0]: got = (2, 'initials')
            elif initials_only(rb) and len(ta) >= 2 and ''.join(t[0] for t in ta) == tb[0]: got = (2, 'initials')
            elif len(ta) >= 2 and len(tb) >= 2 and ta[0] == tb[0] and len(ta) == len(tb):
                x, y = sorted([ta[-1], tb[-1]], key=len)
                if len(x) <= 3 and y.startswith(x) and x != y: got = (2, 'short surname')
            elif ta[0] == tb[0] and (len(ta) == 1) != (len(tb) == 1) and not initials_only(ra) and not initials_only(rb):
                got = (1, 'first name only')
            if got[0] > best[0]: best = got
    return best


def _person_facts(g, gkey):
    """labels, handles, orgs and projects (as group indices) of one group of source records."""
    labels, handles, orgs, projects = [], set(), set(), set()
    for r in g:
        labels += [r['name']] + list(r.get('aliases') or [])
        for k, vs in (r.get('handles') or {}).items():
            if k in ('email', 'tg', 'phone'):
                for v in vs:
                    n = norm_handle(k, v)
                    if len(n) >= 5: handles.add((k, n))
        for l in r.get('links') or []:
            t = gkey.get(l.get('to'))
            if t is None: continue
            (orgs if l['key'] == 'org' else projects).add(t)
    return labels, handles, orgs, projects


def dedupe_people(groups, apart=(), own=()):
    """One human, several records. Merges only on strong evidence: a shared handle with names that fit, or the same
    full name (either script) and a shared org or project. Everything else that may be one person goes to a queue
    with a score and the evidence, best first, for a one-key "Same?" answer. Groups whose name is the user's own (any case
    or script) are dropped. Returns (groups, queue, counts)."""
    apart = {tuple(x) for x in apart}
    gkey = {}
    for gi, g in enumerate(groups):
        for r in g: gkey[f"{r['system']}:{r['id']}"] = gi
    own = {skel(n) for n in own if len(skel(n).split()) >= 2}
    people = [gi for gi, g in enumerate(groups) if any(r.get('kind') == 'person' for r in g) and not all(r.get('cards_only') for r in g)]
    drop = set()
    facts = {}
    for gi in people:
        facts[gi] = _person_facts(groups[gi], gkey)
        if own and any(skel(x) in own for x in facts[gi][0]): drop.add(gi)
    buckets = defaultdict(set)
    for gi in people:
        if gi in drop: continue
        for x in facts[gi][0]:
            t = skel(x).split()
            if not t: continue
            if initials_only(x): buckets['i:' + t[0]].add(gi); continue
            buckets['f:' + t[0]].add(gi)
            if len(t) >= 2: buckets['i:' + ''.join(w[0] for w in t)].add(gi)
    u = Union()
    for gi in people: u.find(gi)
    members_apart = set()
    for a, b in apart:
        if a in gkey and b in gkey: members_apart |= {(gkey[a], gkey[b]), (gkey[b], gkey[a])}
    def tgs(gi): return {n for k, n in facts[gi][1] if k == 'tg'}
    pairs = {}
    for key, gs in buckets.items():
        gs = sorted(gs)
        if len(gs) > 60: continue   # a first name dozens of people share: nothing to learn from it alone
        for i in range(len(gs)):
            for j in range(i + 1, len(gs)):
                a, b = gs[i], gs[j]
                if (a, b) in pairs or (a, b) in members_apart: continue
                score, why = name_match(facts[a][0], facts[b][0])
                if not score: continue
                ev = [why]
                hand = facts[a][1] & facts[b][1]
                org = facts[a][2] & facts[b][2]
                proj = facts[a][3] & facts[b][3]
                clash = bool(tgs(a) and tgs(b) and not tgs(a) & tgs(b))
                if hand: ev.append('same ' + '/'.join(sorted({'email' if k == 'email' else 'phone' if k == 'phone' else 'username' for k, _ in hand})))
                if org: ev.append('same org')
                if proj: ev.append('same project')
                if clash: ev.append('different usernames')
                strong = not clash and ((hand and score >= 1) or (score >= 3 and (org or proj)))
                pairs[(a, b)] = (score + 3 * bool(hand) + 2 * bool(org) + bool(proj) - 2 * clash, ev, strong)
    merged_n = 0
    for (a, b), (sc, ev, strong) in sorted(pairs.items(), key=lambda kv: (-kv[1][0], kv[0])):
        if strong and u.find(a) != u.find(b) and u.join(a, b, members_apart): merged_n += 1
    out, head_of = [], {}
    joined = defaultdict(list)
    for gi in range(len(groups)):
        if gi in drop: continue
        joined[u.find(gi) if gi in u.up else gi].append(gi)
    for root, gis in joined.items():
        g = sorted((r for gi in gis for r in groups[gi]), key=lambda r: (ORDER.get(r['system'], 9), -len(r.get('facts') or []), r['system'], r['id']))
        out.append(g)
        for gi in gis: head_of[gi] = f"{g[0]['system']}:{g[0]['id']}"
    queue = []
    for (a, b), (sc, ev, strong) in pairs.items():
        if a in drop or b in drop or head_of[a] == head_of[b] or sc < 1: continue
        queue.append({'a': head_of[a], 'b': head_of[b], 'score': sc, 'why': ev})
    queue.sort(key=lambda q: (-q['score'], q['a'], q['b']))
    seen, uq = set(), []
    for q in queue:
        k = tuple(sorted((q['a'], q['b'])))
        if k not in seen: seen.add(k); uq.append(q)
    return out, uq, {'merged': merged_n, 'queued': len(uq), 'own_dropped': len(drop)}


APP_NAMES = set("""claude chatgpt gpt codex gemini bard copilot cursor perplexity aider grok deepseek mistral siri alexa cortana
    midjourney devin windsurf lovable replit openclaw manus""".split())


def apps_as_people(records):
    """A "person" that is an assistant or app: its name is a known app or one of the store's own tools, and it has no
    handle. Becomes kind tool (unless the user set the kind themselves). Returns the ids changed."""
    tools = {fold(r['name']) for r in records if r['kind'] == 'tool'}
    changed = []
    for r in records:
        if r['kind'] != 'person' or r.get('kind_by') != 'source' or any(r.get('handles', {}).get(k) for k in ('email', 'tg', 'phone')): continue
        name = fold(r['name'])
        if name in APP_NAMES or name in tools:
            r['kind'], r['kind_by'] = 'tool', 'check'
            changed.append(r['id'])
    return changed


def fold_twins(records):
    """One thing under several kinds: a project, its repo and its Worker with one name. The main record (project
    first, then the one with more sources) keeps the thing; the others point to it (`twin_of`) and give it their
    pointers (repo path, URL). Returns twin id -> main id."""
    by = defaultdict(list)
    for r in records:
        if r['kind'] in ('project', 'tool') and not r.get('cards_only'): by[fold(r['name'])].append(r)
    main_of = {}
    rank = {'project': 0, 'tool': 1}
    order = {'Note': 0, 'Story': 0, 'Repo': 1, 'Code': 1, 'URL': 2}
    for rs in by.values():
        if len(rs) < 2: continue
        main = min(rs, key=lambda r: (rank[r['kind']], -len(r['sources']), -len(r['pack']['facts']), r['id']))
        ptrs = list(main['pack']['pointers'])
        for r in rs:
            if r is main: continue
            main_of[r['id']] = main['id']
            r['twin_of'] = main['id']
            main.setdefault('twins', []).append(r['id'])
            for x in r['pack']['pointers']:
                if all(x['value'] != y['value'] for y in ptrs): ptrs.append(x)
        main['pack']['pointers'] = sorted(ptrs, key=lambda x: order.get(x['label'], 4))[:3]
    return main_of


# chat box placeholders name the chat: "Message <name> on WhatsApp", "Повідомлення для <name> у Telegram"
MESSENGERS = ('whatsapp|telegram|signal|instagram|messenger|linkedin|imessage|sms|slack|discord|beeper|viber|teams|twitter|'
              'facebook|matrix|вайбері|вайбер|телеграмі|телеграм|ватсапі|ватсап|вотсапі|вотсап|сигналі|сигнал|інстаграмі|'
              'інстаграм|месенджері|месенджер')
CHAT_PATTERNS = [
    r"(?:send a message to|message|write to|reply to|text) (.{1,40}?) (?:on|in|via) (?:" + MESSENGERS + r")\b",
    r"(?:повідомлення|написати|напишіть|відповісти|відповідь)(?: для| до)? (.{1,40}?) (?:у|в|через) (?:" + MESSENGERS + r")\b",
]
_CHAT = [re.compile(x) for x in CHAT_PATTERNS]


def chat_target(ctx):
    """The person a chat box's placeholder names, in folded text ("message bear on whatsapp" -> "bear"); the last one
    wins. None when there is no placeholder."""
    best = None
    for rx in _CHAT:
        for m in rx.finditer(ctx or ''):
            if best is None or m.start() >= best[0]: best = (m.start(), m.group(1).strip(" .,:;'\""))
    return best[1] if best and best[1] else None


def names_chat(key, target):
    """The form is the chat's name or one word of it."""
    return bool(target) and (key == target or key in target.split() or target.startswith(key + ' '))


def name_gazetteer(records):
    """First names to keep out of the capitalised-dictionary ordinary words: the system's list of proper names, the
    Ukrainian first names know.py knows, and any first name the user's records carry in both scripts."""
    import know
    out = set()
    try: out |= {fold(w) for w in Path('/usr/share/dict/propernames').read_text().split()}
    except OSError: pass
    for uk, la in list(know.FIRST.items()) + [(v, k) for k, v in know.EXTRA.items()]:
        out |= {fold(uk), fold(la), skel(uk), skel(la)}
    for n in know.MALE | know.FEMALE: out |= {fold(n), skel(n)}
    lat, cyr = set(), set()
    for r in records:
        if r['kind'] != 'person': continue
        for x in [r['name']] + r.get('aliases', []):
            t = WORDS.findall(unlabel(x))
            if len(t) >= 2: (cyr if is_cyrillic(t[0]) else lat).add(skel(t[0]))
    out |= lat & cyr
    return out

# ---------------------------------------------------------------------------------------------------------------
# one record

def ordinary_words(names=()):
    """Ordinary words, case folded: the common list, the dictionary's lower-case words, and its capitalised words
    ("Ukrainian", "Israeli") except first names (`names`, see name_gazetteer)."""
    from know import COMMON
    words = set(COMMON)
    names = set(names)
    try:
        for w in Path('/usr/share/dict/words').read_text().splitlines():
            if w.islower(): words.add(w)
            elif w[:1].isupper() and w[1:].islower() and fold(w) not in names: words.add(fold(w))
    except OSError: pass
    return words


def is_cyrillic(s):
    return bool(re.search(r'[А-Яа-яІіЇїЄєҐґ]', s or ''))


def links_of(group, key_of):
    """The links one group's source records declare ({to: "<system>:<id>", key, n, date}), resolved to record ids:
    [{to, rel, date, rely, src, value, n, note}]."""
    out = []
    for r in group:
        for l in r.get('links') or []:
            to = key_of.get(l.get('to'))
            if to:
                out.append({'to': to, 'rel': 'v_' + l['key'], 'date': l.get('date', ''), 'rely': 0.9, 'src': r['system'],
                            'value': '', 'n': max(1, int(l.get('n') or 1)), 'note': r.get('note_kind') or 'note'})
    return out


def make_record(group, key_of, codius=None):
    head = group[0]
    rid = f"{head['system']}:{head['id']}"
    names, aliases = [], []
    for r in group:
        names.append(r['name']); aliases += r.get('aliases', [])
    name = head['name']
    al = []
    for a in names + aliases:
        a = ' '.join(str(a).split())
        if not a or fold(a) == fold(name) or EMAIL.fullmatch(a) or PHONE.fullmatch(a) or len(a) < 2: continue
        if fold(a) not in {fold(x) for x in al}: al.append(a)
    kind = head['kind']
    handles = defaultdict(list)
    for r in group:
        for k, vs in (r.get('handles') or {}).items():
            for v in vs:
                if v not in handles[k]: handles[k].append(v)
    facts = sorted((f for r in group for f in r.get('facts', [])), key=lambda f: (f['rank'], -int(f['date'].replace('-', '') or 0)))
    seen, uniq = set(), []
    for f in facts:
        key = fold(f['text'])
        if key not in seen: seen.add(key); uniq.append(f)
    role = next((r.get('role') for r in group if r.get('role')), '')
    org = next((r.get('org') for r in group if r.get('org')), '')
    summary = next((r['summary'] for r in group if r.get('summary')), '')
    if kind == 'person':
        who = ', '.join(x for x in [role, ('at ' + org) if org and fold(org) not in fold(role) else ''] if x) or summary
    else:
        who = summary or (uniq[0]['text'] if uniq else '')
    who = one_line(EMAIL.sub('', who), WHO_MAX)
    targets = {}
    if handles.get('email'): targets['mail'] = handles['email'][0]
    if handles.get('tg'): targets['tg'] = handles['tg'][0].lstrip('@')
    urls = [u for r in group for u in r.get('urls', [])]
    pointers = []
    if kind in ('tool', 'project') and codius and fold(name) in codius:
        pointers.append({'label': 'Code' if kind == 'tool' else 'Repo', 'value': codius[fold(name)], 'path': True})
    for u in urls[:1]: pointers.append({'label': 'URL', 'value': u, 'path': False})
    evidence = links_of(group, key_of)
    uniq = [f for f in uniq if fold(f['text']) not in fold(who)]   # the one line already says it
    top = uniq[:4]
    private = any(r.get('private') for r in group) or any(f.get('private') for f in uniq)
    rec = {
        'id': rid, 'kind': kind, 'name': name, 'aliases': al[:20],
        'names': {'uk': next((n for n in [name] + al if is_cyrillic(n)), ''), 'en': next((n for n in [name] + al if not is_cyrillic(n)), '')},
        'who': who, 'related': [], 'evidence': evidence,
        **({'org': org} if org and kind == 'person' else {}),   # the company, for the @ mention list
        'sources': [{'system': r['system'], 'id': r['id']} for r in group],
        'targets': targets, 'kind_by': 'source',
        'handles': dict(handles),   # local, for the user's own card; render() never puts a handle but the one fact, never a phone
        'pack': {'facts': [{k: f[k] for k in ('text', 'source', 'date', 'quote')} for f in top], 'pointers': pointers[:3]},
        'private': private,
    }
    if all(r.get('cards_only') for r in group): rec['cards_only'] = True
    newest = max((f['date'] for f in top if f['date']), default='')
    rec['pack']['newest'] = newest
    return rec


def unlabel(s):
    """A contact's label in brackets ("(Office)", "[old]") is not part of the name."""
    return ' '.join(re.sub(r'\([^)]*\)|\[[^\]]*\]', ' ', str(s or '')).split())


def surfaces_for(rec, ordinary, stop, first_stop=()):
    """Surface form -> how it matches, for one record: full name, aliases, a first+last pair, single tokens, case forms."""
    from know import person_forms
    out = {}
    from know import transliterate
    firsts = set()
    for label in [rec['name']] + list(rec['aliases']):
        t = WORDS.findall(unlabel(label))
        if len(t) >= 2: firsts |= {fold(t[0]), fold(transliterate(t[0]) or t[0])}
    def add(s, how):
        k = fold(s)
        if len(k) < 2 or k in stop: return
        # an ordinary word stays out, unless it is the thing's own name or alias: then it is kept, marked, and
        # counts only when the context decides (surface_flags)
        if ' ' not in k and ((k in ordinary and how not in ('name', 'alias')) or (len(k) < 3 and not (how == 'alias' and s.isupper()))): return
        if how not in ('name', 'alias') and k in first_stop and k in firsts: return   # the user's ordinary word as a first name: never alone
        if k not in out or MATCH[how] > MATCH[out[k]]: out[k] = how
    add(rec['name'], 'name')
    for a in rec['aliases']: add(a, 'alias')
    labels = [rec['name']] + rec['aliases']
    for label in labels:
        parts = WORDS.findall(unlabel(label))
        if rec['kind'] == 'person' and len(parts) >= 2:
            add(parts[0] + ' ' + parts[-1], 'pair')
            add(parts[0], 'first')
            for p in parts[1:]: add(p, 'part')
        elif rec['kind'] != 'person' and len(parts) >= 2:
            pass   # "Lantern Labs": the whole name only, never "Labs" alone
    if rec['kind'] == 'person':
        for form in person_forms({'name': unlabel(rec['name']), 'aliases': [unlabel(a) for a in rec['aliases']]}):
            add(form, 'form')
    return out


def project_roots():
    """Folders whose subfolders are the user's code projects: `projects.roots` in data/drafter.local.json. None by default."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import local
    roots = (local.config().get('projects') or {}).get('roots') or []
    return [local.expand(r) for r in roots if isinstance(r, str) and r.strip()]


def project_dirs(root=None):
    """{folded name: path} of each project folder: the subfolders of `root` (tests), else of the configured roots."""
    out = {}
    for r in ([root] if root is not None else project_roots()):
        try: out.update({fold(d.name): str(d) for d in Path(r).iterdir() if d.is_dir() and not d.name.startswith(('.', '_'))})
        except OSError: pass
    return out


def build(out=None, *, lines=(), now=None, data=None, ordinary=None, codius=None, write=True, slices=None):
    """Build data/entities.json. lines: the user's sent rows (data/typed.jsonl); slices: source records from the caller
    ({system: [records]}), none by default."""
    data = Path(data) if data is not None else DATA
    out = Path(out) if out is not None else data / 'entities.json'
    now = time.time() if now is None else now
    codius = project_dirs(codius)
    slices = {k: list(v) for k, v in (slices or {}).items()}
    fixes = read_fixes(data)
    ids_prev = read_json(data / 'entity-ids.json', {})
    ids_prev = ids_prev if isinstance(ids_prev, dict) else {}
    same_file = read_json(data / 'entity-same.json', {})
    same_file = dict(same_file) if isinstance(same_file, dict) else {}
    pairs = lambda k: [[ids_prev.get(a, a), ids_prev.get(b, b)] for a, b, *_ in (x for x in fixes.get(k) or [] if isinstance(x, list) and len(x) >= 2)]
    same_file['same'] = list(same_file.get('same') or []) + pairs('same')
    same_file['not'] = list(same_file.get('not') or []) + pairs('not_same')
    groups, _ = merge(list(slices.values()), same_file)
    apart = {(a, b) for a, b, *_ in (same_file.get('not') or []) if isinstance(a, str) and isinstance(b, str)}
    groups, same_queue, dstats = dedupe_people(groups, apart, own_names(data))
    overrides = read_json(data / 'entity-overrides.json', {})
    overrides = overrides if isinstance(overrides, dict) else {}
    stop = {fold(s) for s in read_json(data / 'entity-stop.json', []) if isinstance(s, str)} | own_names(data)
    # every source key -> the id of the record it ends up in
    key_of = {}
    for g in groups:
        rid = f"{g[0]['system']}:{g[0]['id']}"
        for r in g: key_of[f"{r['system']}:{r['id']}"] = rid
    records = []
    for g in groups:
        rec = make_record(g, key_of, codius)
        ov = overrides.get(rec['id']) or next((overrides[k] for k in (f"{s['system']}:{s['id']}" for s in rec['sources']) if k in overrides), None)
        if isinstance(ov, dict) and ov.get('kind') in KINDS + ('none',):
            if ov['kind'] == 'none': continue
            rec['kind'], rec['kind_by'] = ov['kind'], ov.get('by', 'me')
        records.append(rec)
    kind_changed = apps_as_people(records)
    model_kinds = read_json(data / 'entity-kinds.json', {})
    for term in (model_kinds if isinstance(model_kinds, dict) else {}):
        k = model_kinds[term]
        if isinstance(k, dict) and k.get('kind') in KINDS and fold(term) not in stop and not any(fold(r['name']) == fold(term) for r in records):
            records.append({'id': 'term:' + fold(term), 'kind': k['kind'], 'name': term, 'aliases': [], 'names': {}, 'who': '', 'related': [],
                            'evidence': [], 'sources': [{'system': 'term', 'id': fold(term)}], 'targets': {}, 'kind_by': k.get('by', 'model'),
                            'handles': {}, 'pack': {'facts': [], 'pointers': [], 'newest': ''}, 'private': False})
    records.sort(key=lambda r: (KINDS.index(r['kind']), fold(r['name'])))
    index = {r['id']: i for i, r in enumerate(records)}
    main_of = fold_twins(records)
    main_ix = {index[a]: index[b] for a, b in main_of.items()}
    def resolve(x):
        x = key_of.get(x, x)
        return x if x in index else key_of.get(ids_prev.get(x, x), ids_prev.get(x, x))
    rows = [row for row in lines]
    units = []   # (text, dest, the lines just before it, chat?, counts for the 30-day heat?)
    recent = {}
    for row in rows:
        t, text, app = (row.get('t') or 0, row.get('text') or '', row.get('app') or '') if isinstance(row, dict) else (0, str(row), '')
        if '⟦drafter-test⟧' in text: continue
        d = dest_of(app)
        prev = recent.get(app)
        ctx = prev[1] if prev and t and prev[0] and float(t) - float(prev[0]) < 600 else ''
        units.append((text, d, ctx, d == 'chat', not t or now - float(t) <= 30 * 86400))
        recent[app] = (t, (ctx + ' ' + text)[-400:])
    # relations declared by the sources and by the user; the matcher's first view of them (declared only, before heat)
    E = declared_edges(records, now, fixes, resolve)
    not_related = [(resolve(x[0]), resolve(x[1])) for x in fixes.get('not_related') or [] if isinstance(x, list) and len(x) >= 2]
    for r in records:
        r['heat'] = 1 + (0.5 if r['pack']['facts'] else 0) - (0.75 if r.get('cards_only') else 0)
    finish_edges(records, E.copy(), None, FLOOR, not_related, main_of)
    # name forms, each marked with what it needs before it counts as a mention
    ordinary = ordinary_words(name_gazetteer(records)) if ordinary is None else set(ordinary)
    own_lower = own_lower_words(u[0] for u in units)
    surfaces = defaultdict(list)
    for i, r in enumerate(records):
        if r.get('cards_only'): continue
        for k, how in surfaces_for(r, ordinary, stop, own_lower).items():
            surfaces[k].append([i, how])
    for form, rid in (x for x in fixes.get('not_this') or [] if isinstance(x, list) and len(x) >= 2):
        i = index.get(resolve(rid))
        k = fold(form)
        if i is not None and k in surfaces:
            surfaces[k] = [h for h in surfaces[k] if h[0] != i]
            if not surfaces[k]: del surfaces[k]
    names = [r['name'] for r in records]
    flags = {k: form_flags(k, v, ordinary, own_lower, names) for k, v in surfaces.items()}
    flags = {k: v for k, v in flags.items() if v}
    # the user's lines, twice: the first pass warms the heat the second decides with; the second counts and pairs
    related = {index[r['id']]: [fold(records[index[x]]['name']) for x in r['related']] for r in records}
    def count(heat):
        typed, single, pair, chat_pair = Counter(), Counter(), Counter(), Counter()
        dropped = unresolved = resolved = 0
        for text, d, ctx, chat, warm in units:
            found = set()
            for got, ok, key, cands in scan(text, surfaces, flags, records, dest=d, ctx_extra=ctx, related=related, heat=heat):
                if got is None: dropped += 1
                elif not ok: unresolved += 1
                else: resolved += 1; found.add(main_ix.get(got, got))   # a repo named is its project named
            if not found: continue
            if warm: typed.update(found)   # the user's typed rows of the last 30 days make the heat
            single.update(found)
            for a in found:
                for b in found:
                    if a < b: pair[(a, b)] += 1; chat_pair[(a, b)] += chat
        return typed, single, pair, chat_pair, {'resolved': resolved, 'unresolved': unresolved, 'dropped': dropped}
    base_heat = {i: r['heat'] for i, r in enumerate(records)}
    typed1 = count(base_heat)[0]
    heat1 = {i: base_heat[i] + typed1.get(i, 0) for i in base_heat}
    seen, single, pair, chat_pair, mstats = count(heat1)
    for i, r in enumerate(records):
        n = seen.get(i, 0)
        r['seen'] = {'typed_30d': n}
        r['heat'] = round(1 + n + (0.5 if r['pack']['facts'] else 0) - (0.75 if r.get('cards_only') else 0), 3)
    # names said together, by NPMI: a popular name gains nothing from being everywhere
    co = {}
    for (a, b), c in pair.items():
        v = npmi(c, single[a], single[b], len(units))
        if v > 0:
            why = 'often together in chats' if chat_pair[(a, b)] * 2 >= c else 'often together in your lines'
            co[(records[a]['id'], records[b]['id'])] = (CO_W * v, why)
    finish_edges(records, E.copy(), dict(co), FLOOR, not_related)
    shown = lambda: sum(len(r['relations']) for r in records if r['id'] not in main_of)
    unfolded = shown()
    rstats = finish_edges(records, E, co, FLOOR, not_related, main_of)
    rstats.update(co_pairs=len(co), twins=len(main_of), twin_lines_removed=unfolded - shown())
    ids_map = id_map(data, records, key_of)
    same_pending = len(same_queue)
    # shared name forms: probably one person under several records (every pair queued at score 2+), or truly shared
    likely = {tuple(sorted((q['a'], q['b']))) for q in same_queue if q['score'] >= 2}
    shared = [k for k, v in flags.items() if 'shared' in v]
    def dup(k):
        ids = sorted({records[i]['id'] for i, _ in surfaces[k]})
        return all((a, b) in likely for x, a in enumerate(ids) for b in ids[x + 1:])
    dstats.update(shared_forms=len(shared), shared_probable_duplicates=sum(1 for k in shared if dup(k)))
    dstats['shared_truly'] = dstats['shared_forms'] - dstats['shared_probable_duplicates']
    dstats['kind_changed'] = len(kind_changed)
    store = {'version': 1, 'built': now, 'built_day': day(now), 'failed': [], 'same_pending': same_pending,
             'same_queue': same_queue[:500], 'dedupe_stats': dstats,
             'records': records, 'surfaces': dict(surfaces), 'surface_flags': {k: flag_record(v) for k, v in flags.items()},
             'relation_stats': rstats, 'mention_stats': mstats}
    if write:
        atomic(out, json.dumps(store, ensure_ascii=False, separators=(',', ':')) + '\n')
        atomic(data / 'entity-ids.json', json.dumps(ids_map, ensure_ascii=False, indent=1) + '\n')
    return store


def id_map(data, records, key_of):
    """data/entity-ids.json: an old id -> the id it lives on under now, so a pick or mention survives a merge."""
    old = read_json(data / 'entity-ids.json', {})
    old = old if isinstance(old, dict) else {}
    now_ids = {r['id'] for r in records}
    prev = read_json(data / 'entities.json', {})
    for r in (prev.get('records') or []) if isinstance(prev, dict) else []:
        rid = r.get('id')
        if rid and rid not in now_ids:
            for s in r.get('sources') or []:
                k = f"{s.get('system')}:{s.get('id')}"
                if k in key_of and key_of[k] in now_ids: old[rid] = key_of[k]; break
    for k, v in key_of.items():
        if k != v and k not in now_ids: old[k] = v
    return {k: v for k, v in old.items() if k not in now_ids}


def sent_rows(path):
    try:
        with Path(path).open() as f:
            for line in f:
                try: row = json.loads(line)
                except ValueError: continue
                if isinstance(row, dict) and isinstance(row.get('text'), str): yield row
    except FileNotFoundError: return


# ---------------------------------------------------------------------------------------------------------------
# packs: a fixed template over stored records (the app's EntityRules.render is its twin)

def ptr_text(p):
    return f"{p['label']}: `{p['value']}`" if p.get('path') else f"{p['label']}: {p['value']}"


def stale(rec, today):
    newest = (rec.get('pack') or {}).get('newest') or ''
    if not newest: return True
    try: return (time.mktime(time.strptime(today, '%Y-%m-%d')) - time.mktime(time.strptime(newest, '%Y-%m-%d'))) / 86400 > STALE_DAYS
    except ValueError: return True


def fact_text(f):
    t = f['text']
    body = f'“{t}”' if f.get('quote') else t
    when = f", {f['date']}" if f.get('date') else ''
    return f"{body} ({f['source']}{when})."


def cut(s, n):
    """one_line for text already clean: the twin of EntityRules.cut."""
    if len(s) <= n: return s
    head = s[:n - 1]
    c = head.rsplit(' ', 1)[0] if ' ' in head else head
    return c.rstrip(' ,;.:-') + '…'


def render(rec, level, *, today, facts=None, pointers=None, who_max=None):
    """One bullet for one entity. level 2: name, who, one pointer (<= 160); level 3: full (<= 600). Level 1: ''."""
    if level <= 1: return ''
    name, pack, kw = rec['name'], rec.get('pack') or {}, KIND_WORD.get(rec['kind'], rec['kind'])
    ptrs = pack.get('pointers') or []
    who = rec.get('who') or ''
    if who_max is not None: who = cut(who, who_max) if who_max > 1 else ''
    if level == 2:
        tail = (' ' + (f"`{ptrs[0]['value']}`" if ptrs[0].get('path') else ptrs[0]['value'])) if ptrs else ''
        base = f"- **{name}**"
        if who:
            room = LINE_MAX - len(base + ' - .' + tail)
            who = cut(who, room) if room > 12 else ''
        return base + ((f" - {who}" + ('' if who.endswith('…') else '.')) if who else f" ({kw}).") + tail
    fs = list(pack.get('facts') or []) if facts is None else list(facts)
    ps = list(ptrs) if pointers is None else list(pointers)
    old = stale(rec, today)
    while True:
        body = f"- **{name}** ({kw})" + (f" - {who}" if who else '') + ('; no recent notes.' if old else '' if who.endswith('…') else '.')
        if not old:
            for f in fs: body += ' ' + fact_text(f)
        if ps: body += ' ' + ' · '.join(ptr_text(p) for p in ps)
        if len(body) <= FULL_MAX: return body
        if fs and not old: fs.pop(); continue
        if len(ps) > 1: ps = ps[:1]; continue
        return cut(body, FULL_MAX)


def block(items, *, today=None, limit=BLOCK_MAX):
    """The one block at the end of a message. items: [(record, level, mentions)]. Over the budget, drop in order:
    facts after the first two, pointers after the first, then whole entities step down to one line, the least
    mentioned first. The name and the first pointer are never dropped."""
    today = today or time.strftime('%Y-%m-%d')
    items = [(r, lv, m) for r, lv, m in items if lv >= 2]
    if not items: return ''
    state = [{'rec': r, 'level': lv, 'm': m, 'facts': None, 'ptrs': None} for r, lv, m in items]
    def text():
        lines = [render(s['rec'], s['level'], today=today, facts=s['facts'], pointers=s['ptrs'], who_max=s.get('who')) for s in state]
        return HEADER + '\n' + '\n'.join(lines)
    t = text()
    if len(t) <= limit: return t
    for s in state:
        if s['level'] == 3: s['facts'] = (s['rec'].get('pack') or {}).get('facts', [])[:2]
    t = text()
    if len(t) <= limit: return t
    for s in state:
        if s['level'] == 3: s['ptrs'] = (s['rec'].get('pack') or {}).get('pointers', [])[:1]
    t = text()
    order = sorted(range(len(state)), key=lambda i: (state[i]['m'], -i))
    for i in order:
        if len(t) <= limit: return t
        if state[i]['level'] == 3: state[i]['level'] = 2; t = text()
    for i in order:
        if len(t) <= limit: return t
        state[i]['who'] = 0; t = text()
    return t


def brief(records, rec, *, today=None, limit=BRIEF_MAX):
    """"context for <name>": the entity in full, then its related ones, project first, then people, tools, documents."""
    today = today or time.strftime('%Y-%m-%d')
    by_id = {r['id']: r for r in records}
    rank = {'project': 0, 'org': 1, 'person': 2, 'tool': 3, 'doc': 4, 'place': 5}
    rel = sorted((by_id[x] for x in rec.get('related', []) if x in by_id), key=lambda r: (rank.get(r['kind'], 9), -r.get('heat', 0)))
    out = HEADER + '\n' + render(rec, 3, today=today)
    for r in rel:
        line = render(r, 2, today=today)
        if len(out) + 1 + len(line) > limit: break
        out += '\n' + line
    return out


# ---------------------------------------------------------------------------------------------------------------
# reading the store (the engine's /context and /entity, the CLI)

class Store:
    def __init__(self, path=None):
        self.path = Path(path) if path else DATA / 'entities.json'
        self.stamp, self.data = None, {'records': [], 'surfaces': {}}

    def reload(self):
        try:
            st = self.path.stat(); stamp = (st.st_mtime_ns, st.st_size)
            if stamp == self.stamp: return self.data
            d = json.loads(self.path.read_text())
            if isinstance(d, dict) and isinstance(d.get('records'), list):
                self.data, self.stamp = d, stamp
        except FileNotFoundError:
            self.data, self.stamp = {'records': [], 'surfaces': {}}, None
        except (OSError, ValueError): pass
        return self.data

    def find(self, q, limit=8):
        """Exact surface first (with how it matched), then a prefix over names and aliases, warmest first."""
        d = self.reload(); recs = d.get('records', [])
        q = fold(str(q or '').lstrip(';@'))
        if len(q) < 2: return []
        hits = [(recs[i], MATCH.get(how, 1)) for i, how in d.get('surfaces', {}).get(q, []) if i < len(recs)]
        if not hits:
            hits = [(r, 0.5) for r in recs if any(fold(n).startswith(q) or any(w.startswith(q) for w in fold(n).split())
                                                  for n in [r['name']] + r.get('aliases', []))]
        hits.sort(key=lambda x: (-x[1], x[0].get('cards_only', False), -x[0].get('heat', 0), x[0]['name']))
        out, seen = [], set()
        for r, _ in hits:
            if r['id'] not in seen: seen.add(r['id']); out.append(r)
        return out[:limit]

    def context(self, q, level=2, today=None):
        found = [r for r in self.find(q) if not r.get('cards_only')]
        if not found: return {'q': q, 'found': 0}
        r = found[0]
        level = max(1, min(3, int(level)))
        return {'q': q, 'found': len(found), 'id': r['id'], 'name': r['name'], 'kind': r['kind'], 'level': level,
                'text': block([(r, level, 1)], today=today) if level >= 2 else r['name'],
                'pointers': (r.get('pack') or {}).get('pointers', []), 'private': bool(r.get('private')),
                'built': self.data.get('built_day', ''), 'who': r.get('who', ''), 'facts': (r.get('pack') or {}).get('facts', []),
                'others': [{'id': o['id'], 'name': o['name'], 'kind': o['kind'], 'who': o.get('who', '')} for o in found[1:5]]}

    def entity(self, q):
        return {'q': q, 'entities': [{'id': r['id'], 'name': r['name'], 'kind': r['kind'], 'who': r.get('who', ''),
                                      'aliases': r.get('aliases', [])[:6], 'targets': {k: v for k, v in r.get('targets', {}).items() if k != 'tg'},
                                      'related': r.get('related', [])[:6], 'relations': r.get('relations', [])[:6]}
                                     for r in self.find(q) if not r.get('cards_only')]}

    def brief(self, q, today=None):
        found = [r for r in self.find(q) if not r.get('cards_only')]
        if not found: return {'q': q, 'found': 0}
        return {'q': q, 'found': len(found), 'id': found[0]['id'], 'text': brief(self.data['records'], found[0], today=today)}


# ---------------------------------------------------------------------------------------------------------------
# kinds for leftovers: a hook, off by default (proposal 1.3). The answer is one word from KINDS or "none".

CLASSIFY_PROMPT = ('One word answer. What kind of thing is "{name}" most likely, as a name a person writes in notes? '
                   'Choose from: person, org, project, tool, doc, place, none.')


def classify(names, ask, data=DATA):
    """Ask `ask(name) -> word` for each leftover name; keep only answers in the fixed list. Results go to
    data/entity-kinds.json (by: the asker); the user's own overrides always win at build time."""
    kinds = read_json(data / 'entity-kinds.json', {})
    kinds = kinds if isinstance(kinds, dict) else {}
    done = 0
    for n in names:
        if n in kinds: continue
        word = (ask(n) or '').strip().lower().strip('.')
        if word in KINDS or word == 'none':
            kinds[n] = {'kind': word, 'by': getattr(ask, 'by', 'model'), 'at': day(time.time())}; done += 1
    atomic(data / 'entity-kinds.json', json.dumps(kinds, ensure_ascii=False, indent=1) + '\n')
    return done


def leftovers(data=DATA):
    """Names with no kind: dictionary terms in know.json (the pack calls them `term`)."""
    pack = read_json(data / 'know.json', {})
    return sorted({e['name'] for e in pack.get('entries', []) if isinstance(e, dict) and e.get('kind') == 'term' and e.get('name')})


def ask_claude(name):
    """Only the name and the kind list go out, and only when Settings' entityClassify is on (engine/cloud.py)."""
    import cloud, router
    try: st = json.loads((DATA / 'settings.json').read_text())
    except Exception: st = {}
    if not (cloud.allowed('entities', st) and router.online()): return None
    import claude_worker
    return claude_worker.ask(CLASSIFY_PROMPT.format(name=name.replace('"', '')), 20)
ask_claude.by = 'claude'


def engine_headers():
    """JSON headers plus the engine's token from data/engine.token (DRAFTER_DATA when set), when there is one."""
    h = {'Content-Type': 'application/json'}
    try: t = (Path(os.environ.get('DRAFTER_DATA') or ROOT / 'data') / 'engine.token').read_text().strip()
    except OSError: t = ''
    if t: h['X-Drafter-Token'] = t
    return h


def ask_local(name):
    """The warm local model through the engine's /classify route, under its guard. The route is not built yet
    (step 4): until then this returns None and nothing is classified."""
    import urllib.request
    try:
        req = urllib.request.Request('http://127.0.0.1:8798/classify', json.dumps({'name': name}).encode(), engine_headers())
        return json.loads(urllib.request.urlopen(req, timeout=5).read()).get('kind')
    except Exception:
        return None
ask_local.by = 'local'


def correct(entity_id, key, data=DATA):
    """The one-key kind fix (1 person · 2 org · 3 project · 4 tool · 5 doc · 6 place · 0 not a thing)."""
    kind = KIND_KEYS.get(str(key))
    if not kind: return False
    ov = read_json(data / 'entity-overrides.json', {})
    ov = ov if isinstance(ov, dict) else {}
    ov[entity_id] = {'kind': kind, 'by': 'me', 'at': day(time.time())}
    atomic(data / 'entity-overrides.json', json.dumps(ov, ensure_ascii=False, indent=1) + '\n')
    return True


def stats(store):
    recs = store.get('records', [])
    kinds = Counter(r['kind'] for r in recs)
    return {'records': len(recs), 'kinds': dict(kinds), 'cards_only': sum(1 for r in recs if r.get('cards_only')),
            'sources': dict(Counter(s['system'] for r in recs for s in r['sources'])),
            'merged_records': sum(1 for r in recs if len(r['sources']) > 1),
            'with_dated_fact': sum(1 for r in recs if any(f.get('date') for f in r['pack']['facts'])),
            'private_allowed': sum(1 for r in recs if r.get('private')),
            'surfaces': len(store.get('surfaces', {})), 'ambiguous_surfaces': sum(1 for v in store.get('surfaces', {}).values() if len({i for i, _ in v}) > 1),
            'forms': sum(1 for v in store.get('surfaces', {}).values() if any(h == 'form' for _, h in v)),
            'same_pending': store.get('same_pending', 0), 'failed': store.get('failed', [])}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['build', 'stats', 'pack', 'context', 'classify', 'fix'])
    ap.add_argument('query', nargs='?', default='')
    ap.add_argument('rest', nargs='*', default=[])
    ap.add_argument('--level', type=int, default=3)
    ap.add_argument('--out', type=Path, default=None)
    ap.add_argument('--with', dest='asker', choices=['local', 'claude'], default='local')
    args = ap.parse_args()
    if args.command == 'build':
        t0 = time.time()
        store = build(args.out, lines=sent_rows(DATA / 'typed.jsonl'))
        print(json.dumps({**stats(store), 'ms': int((time.time() - t0) * 1000)}))
    elif args.command == 'stats':
        print(json.dumps(stats(Store(args.out).reload())))
    elif args.command == 'pack':
        print(json.dumps(Store(args.out).context(args.query, args.level), ensure_ascii=False, indent=1))
    elif args.command == 'context':
        print(json.dumps(Store(args.out).brief(args.query), ensure_ascii=False, indent=1))
    elif args.command == 'fix':   # entities.py fix not_related <id> <id> | related <id> <id> [why] | not_this <form> <id> | same | not_same
        what, ab = args.query, args.rest
        if what not in FIX_KINDS or len(ab) < 2: ap.error('fix ' + '|'.join(FIX_KINDS) + ' <a> <b> [why]')
        save_fix(what, ab[0], ab[1], ' '.join(ab[2:]))
        print('saved; the next build applies it')
    elif args.command == 'classify':
        print(classify(leftovers(), ask_claude if args.asker == 'claude' else ask_local), 'classified')
