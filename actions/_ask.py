"""Shared helper: ask the warm model for a small JSON object."""
import json, re


def fields(ask, instruction, line, keys):
    p = (instruction + "\nВідповідай лише JSON з ключами: " + ", ".join(keys) + ".\n"
         "Текст: «" + line + "»")
    out = ask(p)
    m = re.search(r"\{.*", out, re.S)
    if not m: return {}
    s = m.group(0)
    if not s.rstrip().endswith("}"): s += "}"
    try:
        d = json.loads(s)
    except Exception:
        # cut off mid-string: take each "key": "value" as far as it goes
        d = {k: m.group(1) for k in keys for m in [re.search(r'"' + k + r'"\s*:\s*"((?:[^"\\]|\\.)*)', s)] if m}
    return {k: (str(d.get(k)).strip() if d.get(k) not in (None, "", "null") else "") for k in keys}
