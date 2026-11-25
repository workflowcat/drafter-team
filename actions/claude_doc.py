"""Claude Doc: "зроби док про ...", "створи документ: ...", "make a doc about ..."."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import local
from _ask import fields
import _claude

ID = "claude.doc"
NEEDS = ("claude",)   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(зроби|створи|напиши|make|create|write)\s+(мені\s+|a\s+)?(док|документ|doc|document)\b")


def extract(line, ask):
    f = fields(ask, "З команди зробити документ витягни назву документа і що в ньому має бути (коротко, мовою команди).",
               line, ["title", "brief"])
    if not f.get("brief") and not f.get("title"): return None
    return {"chip": f"Claude Doc «{f.get('title') or f.get('brief')[:40]}» (Claude + docs, in the background)", "run": {"kind": "python"},
            "fields": {"title": f.get("title", ""), "brief": f.get("brief", "")}}


def run(fields):
    return _claude.run(ID, "anthropic-skills:docs", f"Make a Claude Doc. Title: {fields['title']!r}. What it should hold: {fields['brief']!r}. "
                       "Write it in " + local.possessive() + " language from the brief; reply with its link.", ["Skill", "Read", "mcp__*"])
