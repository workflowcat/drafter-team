"""Artifact page: "зроби сторінку про ...", "make an artifact page for ...". PixelKit on a Claude Design canvas first."""
import re
from _ask import fields
import _claude

ID = "artifact.page"
NEEDS = ("claude",)   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(зроби|створи|make|create)\s+(мені\s+|an?\s+)?(сторінку|пейдж|артефакт|page|artifact)\b")


def extract(line, ask):
    f = fields(ask, "З команди зробити сторінку витягни назву і що на ній має бути (коротко, мовою команди).", line, ["title", "brief"])
    if not f.get("brief") and not f.get("title"): return None
    return {"chip": f"Page «{f.get('title') or f.get('brief')[:40]}» on Claude Design canvas (Claude + pixelkit, in the background)",
            "run": {"kind": "python"}, "fields": {"title": f.get("title", ""), "brief": f.get("brief", "")}}


def run(fields):
    return _claude.run(ID, "pixelkit", f"Make this as a PixelKit page on a Claude Design canvas first (Artifact quickstart, intent design). "
                       f"Title: {fields['title']!r}. What it should show: {fields['brief']!r}. Reply with the canvas link.",
                       ["Skill", "Read", "Write", "Artifact", "mcp__*"], minutes=15)
