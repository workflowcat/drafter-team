"""Names before and after the names reference (2026-11-15): the knowledge pack (data/know.json) against the names
reference (data/names.json) as the word finisher's second source, and the voice glossary from the dictionary
against the one ordered by use. Numbers only; no line is printed.

    .venv/bin/python bench/names_bench.py [--data data] [--skip-replay]

1. Replay (bench/typescore.py simulate on data/replay-fresh.json, his words from before the last retrain without the
   test lines, as bench/ngram.py): words alone, words + know, words + names.
2. Names on held-out lines (bench/held.py: the replay lines, and every line he wrote after the last retrain): at every word that names a known thing, with 2 and 3
   letters typed, what the finisher offers: the whole name (hit), another word (wrong) or nothing. Also wrong offers
   from the second source at capitalised words that are not names.
3. Voice: in his spoken lines after the last retrain (takes, Voice Notes; names ranked on his lines before it), the share of name mentions whose name is in the first 60 glossary
   terms Whisper reads, and the mishearing rules.
"""
import argparse, json, re, sys, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'engine')); sys.path.insert(0, str(ROOT / 'bench'))
import know, names
from words import finish_with_source

WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*")


def name_words(store):
    """Capitalised words that name exactly one shown, non-card entry."""
    owner = {}
    for e in store['entries']:
        if e.get('hidden') or e.get('card'): continue
        for w in names.surfaces(e) + e.get('parts', []):
            if w[:1].isupper() and len(w) >= 4 and names.fold(w) not in e.get('common', []):
                owner.setdefault(w, set()).add(e['id'])
    return {w for w, ids in owner.items() if len(ids) == 1}


def name_offers(W, packs, lines, targets):
    out = {k: Counter() for k in packs}
    for line in lines:
        for m in WORD.finditer(line):
            w = m.group(0)
            before = line[:m.start()]
            if w in targets:
                for n in (2, 3):
                    if len(w) <= n: continue
                    for k, p in packs.items():
                        got, src = finish_with_source(W, before + w[:n], knowledge=p)
                        tag = 'hit' if got == w[n:] else ('wrong' if got else 'none')
                        out[k][f'{n}:{tag}'] += 1
                        if got and src == 'know': out[k][f'{n}:second_{tag}'] += 1
            elif w[:1].isupper() and len(w) >= 4:
                for k, p in packs.items():
                    got, src = finish_with_source(W, before + w[:3], knowledge=p)
                    if src == 'know': out[k]['other:' + ('right' if got == w[3:] else 'wrong')] += 1
    return out


def voice(store, rows, terms_before, terms_after):
    single, multi = names.mention_index({e['id']: e for e in store['entries']})
    common = {e['id']: set(e.get('common', [])) for e in store['entries']}
    labels = {e['id']: {names.fold(x) for x in names.labels(e)} for e in store['entries']}
    res = {}
    for k, terms in (('before', terms_before), ('after', terms_after)):
        g = {names.fold(t) for t in terms[:60]}
        n = covered = 0
        for r in rows:
            for eid in names.mentions(r['text'], single, multi, common):
                n += 1; covered += bool(labels[eid] & g)
        res[k] = {'mentions': n, 'in_glossary': covered, 'share%': round(100 * covered / max(1, n), 1)}
    return res


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--data', type=Path, default=ROOT / 'data')
    ap.add_argument('--skip-replay', action='store_true')
    a = ap.parse_args()
    store = json.loads((a.data / 'names.json').read_text())
    import ngram
    from retrain_state import last_retrain
    from held import Held
    t0 = time.time()
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus(cut))
    kp = know.Pack(a.data / 'know.json'); kp.reload()
    # the reference as it would have been at the cut: context from his lines before it only (no chats: they hold no date)
    corpus = names.corpus_rows(a.data)
    early = names.build_entries(entities=names.read_json(a.data / 'entities.json', {}), know=names.read_json(a.data / 'know.json', {}),
                                words=names.read_json(a.data / 'words.json', {}), edits=names.read_json(a.data / 'names-edits.json', []),
                                rows=[r for r in corpus if (r.get('t') or 0) < cut])
    npk = names.Pack().load({'entries': names.ordered(early)})
    packs = {'words': None, 'know': kp, 'names': npk}
    print(json.dumps({'cut': time.strftime('%Y-%m-%d', time.localtime(cut)), 'vocab': len(W.vocab), 'know_entries': len(kp.entries), 'names_entries': len(npk.entries), 'load_s': round(time.time() - t0, 1)}))
    held = sorted(Held().texts | {r['text'] for r in corpus if (r.get('t') or 0) >= cut})
    targets = name_words(store)
    for k, c in name_offers(W, packs, held, targets).items():
        print(json.dumps({'names_on_held': k, **dict(sorted(c.items()))}))
    if not a.skip_replay:
        import typescore as ts
        items = json.loads((a.data / 'replay-fresh.json').read_text())
        rows = {(i, p): {'heal': '', 'toks': [], 'prefill_ms': 0} for i, it in enumerate(items) for p in range(1, len(it['text']))}
        for k, p in packs.items():
            ts.show(f'replay {k}', ts.simulate(items, rows, lambda r, b, s, p=p: (finish_with_source(W, b, knowledge=p)[0], 0)))
    spoken = [json.loads(l) for l in (a.data / 'corpus.jsonl').read_text().splitlines() if l.strip()]
    spoken = [r for r in spoken if r.get('src') in ('take', 'vnotes') and (r.get('t') or 0) >= cut]   # ranked on lines before the cut
    store = {'entries': names.ordered(early)}
    import dictionary
    d = json.loads((a.data / 'words.json').read_text())
    base = [w['text'] for w in d.get('words', []) if dictionary.spelling(w)]
    order = {'voicenotes': 0, 'menu': 1, 'typing': 2, 'aleph-live': 3, 'aleph': 4}
    base = [w['text'] for w in sorted(d.get('words', []), key=lambda w: order.get(w.get('source'), 9)) if dictionary.spelling(w)]
    after, heard = names.words_view({'terms': base, 'heard': d.get('heard', {})}, store)
    v = voice(store, spoken, base, after)
    v['hint'] = voice(store, spoken, base, names.voice_hint(store))['after']
    print(json.dumps({'voice_lines': len(spoken), **v, 'heard_rules': {'before': len(d.get('heard', {})), 'after': len(heard)},
                      'terms': {'before': len(base), 'after': len(after)}}))
