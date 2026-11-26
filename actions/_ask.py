"""Shared helper: ask the warm model for a small JSON object, framed in the language of the line."""
import json, re

CYRILLIC = re.compile(r"[Ѐ-ӿ]")


def is_cyrillic(line):
    """True when the line holds any Cyrillic letter: the prompt is then framed in Ukrainian, else in English."""
    return bool(CYRILLIC.search(line or ""))


def prompt(instruction, line, keys):
    """The prompt the model sees. `instruction` is a string, or {"uk": ..., "en": ...} picked by the line's script."""
    uk = is_cyrillic(line)
    if isinstance(instruction, dict): instruction = instruction["uk" if uk else "en"]
    if uk:
        return instruction + "\nВідповідай лише JSON з ключами: " + ", ".join(keys) + ".\nТекст: «" + line + "»"
    return instruction + "\nReply with JSON only using keys: " + ", ".join(keys) + '.\nText: "' + line + '"'


def fields(ask, instruction, line, keys):
    out = ask(prompt(instruction, line, keys)) or ""
    m = re.search(r"\{.*", out, re.S)
    if not m: return {}
    raw = m.group(0)
    s = raw if raw.rstrip().endswith("}") else raw + "}"
    try:
        d = json.loads(s)
    except Exception:
        # cut off mid-string: take each "key": "value" as far as it goes (in the raw text, without the added "}")
        d = {k: m.group(1) for k in keys for m in [re.search(r'"' + k + r'"\s*:\s*"((?:[^"\\]|\\.)*)', raw)] if m}
    if not isinstance(d, dict): return {}
    return {k: (str(d.get(k)).strip() if d.get(k) not in (None, "", "null") else "") for k in keys}
