"""Which quick-command trigger fires by mistake least (17 November 2026, Andrii: "a bunch of quick commands and triggers").

Counts false fires per 10,000 lines for each candidate, matched by PHYSICAL key (so a trigger works in ABC and in
Ukrainian-PC alike: in Ukrainian-PC the `;` key types ж, `,` б, `.` ю, `\\` ʼ, `/` a full stop). A typed trigger fires
when its key pair comes at the start of a line or after a space; "+letter" = the picker opens only when a letter key
follows the pair (so "..." typed as `///` never opens it). Corpora, never his text:
- chat en / chat uk: made-up lines from templates below (rates of smileys, ellipses and paths are this file's own guess);
- urls: generated addresses, bare and inside sentences, protocol-relative (`//cdn...`), Windows shares (`\\\\srv`);
- code: real lines of the Python standard library and of app/*.swift (open source code, not his writing).
Voice: a take that is only a command ("free tomorrow 30", "вільно завтра 30") against made-up dictated sentences.

    .venv/bin/python -B bench/triggers.py
"""
import glob, random, re, sys, sysconfig
from pathlib import Path

N = 10_000
rng = random.Random(17)
ROOT = Path(__file__).resolve().parents[1]

# physical key -> (ABC char, Ukrainian-PC char), read with UCKeyTranslate on this Mac (17 November 2026)
KEYS = {"semicolon": (";", "ж"), "slash": ("/", "."), "comma": (",", "б"), "period": (".", "ю"), "backslash": ("\\", "ʼ")}
TYPED = {";": ["semicolon"], ";;": ["semicolon"] * 2, "//": ["slash"] * 2, ",,": ["comma"] * 2, "..": ["period"] * 2,
         "\\\\": ["backslash"] * 2}

EN_WORDS = ("hi ok so we can meet tomorrow at noon send me the file please thanks great sounds good let me check "
            "the draft budget for next week call me when you are free i will be late sorry the link is below and/or "
            "maybe later lol yes no what about friday its done fixed it see you").split()
UK_WORDS = ("привіт ок так давай завтра зустрінемось в офісі скинь мені файл будь ласка дякую супер звучить добре зараз "
            "гляну чернетку бюджет на наступний тиждень набери коли будеш вільний трохи запізнюсь вибач посилання нижче "
            "може пізніше ага ні а що з пʼятницею готово виправив побачимось жовтий жʼю журнал жити бюджет").split()
TAILS_EN = ["", "", "", ".", "!", "?", " :)", " ;)", " ;-)", "...", " ...", " / ", " - ok", " (see ~/Docs/a.txt)", " 10/12", " -> done"]
TAILS_UK = ["", "", "", ".", "!", "?", " :)", " ;)", "...", " ...", " ..", " - ок", " 10/12", " ну .. ок"]
HEADS = ["", "", "", "", "", "... ", ".. ", "/ ", "// ", "@ana ", ";) "]


def chat(words, tails):
    out = []
    for _ in range(N):
        line = rng.choice(HEADS) + " ".join(rng.choice(words) for _ in range(rng.randint(2, 12))) + rng.choice(tails)
        if rng.random() < 0.08: line += " " + rng.choice(words) + "... " + rng.choice(words)
        out.append(line)
    return out


def urls():
    hosts = ["example.com", "docs.example.org", "cdn.example.net", "мій-сайт.укр", "a.b.example.io"]
    paths = ["", "/", "/a/b", "/files//double", "/path;param=1", "/q?x=1&y=2", "/../up", "/~me/x.html"]
    forms = ["https://{h}{p}", "http://{h}{p}", "see https://{h}{p} now", "//{h}{p}", "src=\"//{h}{p}\"",
             "\\\\srv\\share\\{h}", "file:///tmp/x/{h}", "{h}{p}", "go to {h}{p} ok", "ftp://{h}{p}"]
    return [rng.choice(forms).format(h=rng.choice(hosts), p=rng.choice(paths)) for _ in range(N)]


def code():
    lines = []
    for f in sorted(glob.glob(sysconfig.get_paths()["stdlib"] + "/*.py"))[:400] + sorted(glob.glob(str(ROOT / "app/*.swift"))):
        try: lines += [l.rstrip() for l in open(f, encoding="utf-8", errors="ignore") if l.strip()]
        except OSError: pass
    rng.shuffle(lines)
    return lines[:N]


def to_keys(line, uk):
    """The line as a list of (physical key or None, char): the trigger keys by name, every other char as itself."""
    rev = {v[1 if uk else 0]: k for k, v in KEYS.items()}
    return [(rev.get(c), c) for c in line]


def fires(line, trig, uk, letter):
    ks = to_keys(line, uk)
    want = TYPED[trig]
    n = len(want)
    for i in range(len(ks) - n + 1):
        if [k for k, _ in ks[i:i + n]] != want: continue
        if i > 0 and not ks[i - 1][1].isspace(): continue
        if letter:
            nxt = ks[i + n][1] if i + n < len(ks) else ""
            if not nxt.isalpha() or ks[i + n][0] is not None: continue
        return True
    return False


VOICE_CMDS = {"free": r"(today|tomorrow|monday|friday|next week)( \d+)?", "docs": r"\w+( \w+)?", "meetings": r"(today|tomorrow)",
              "links": r"\w+", "вільно": r"(сьогодні|завтра|у понеділок|у пʼятницю)( \d+)?", "документи": r"\w+( \w+)?",
              "зустрічі": r"(сьогодні|завтра)"}
VOICE_RX = re.compile(r"^(%s) (?:%s)$" % ("|".join(VOICE_CMDS), "|".join(f"(?:{v})" for v in VOICE_CMDS.values())), re.I)


def dictated(words):
    starts = ["free", "docs", "meetings", "links", "вільно", "документи", "зустрічі", "", "", "", "", "", ""]
    out = []
    for _ in range(N):
        n = rng.choice([1, 1, 2, 2, 3, 5, 9])
        out.append(" ".join(([rng.choice(starts)] if rng.random() < 0.3 else []) + [rng.choice(words) for _ in range(n)]).strip())
    return out


def main():
    corpora = {"chat en": (chat(EN_WORDS, TAILS_EN), False), "chat uk": (chat(UK_WORDS, TAILS_UK), True),
               "urls": (urls(), False), "code": (code(), False)}
    print(f"false fires per {N:,} lines (open on the pair / only when a letter follows)")
    print(f"{'trigger':8}" + "".join(f"{k:>16}" for k in corpora))
    for trig in TYPED:
        row = f"{trig:8}"
        for name, (lines, uk) in corpora.items():
            a = sum(fires(l, trig, uk, False) for l in lines) * N // len(lines)
            b = sum(fires(l, trig, uk, True) for l in lines) * N // len(lines)
            row += f"{f'{a} / {b}':>16}"
        print(row)
    for name, words in (("en", EN_WORDS), ("uk", UK_WORDS)):
        lines = dictated(words)
        print(f"voice {name}: {sum(bool(VOICE_RX.match(l)) for l in lines) * N // len(lines)} per {N:,} made-up takes "
              f"(a take that is only a command and its words)")


if __name__ == "__main__":
    main()
