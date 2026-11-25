"""Follow-up in Aleph ("what waits on me"): "фоловап з Савою в п'ятницю по договору", "follow up with Mila on the invoice monday"."""
import re
from _when import parse, show
from _ask import fields
import _aleph

ID = "followup"
NEEDS = ("aleph",)   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(фоловап|фолоуап|фоллоу ?ап|follow[- ]?up|нагадатися|пінгонути|пінганути)\b")


def extract(line, ask):
    due, _, _ = parse(line)
    if not due: return None
    f = fields(ask, "З команди про фоловап витягни, що саме треба зробити: з дієсловом, з ким і про що (усі деталі), мовою команди, без дати й часу і без слова «фоловап».",
               line, ["what"])
    what = f.get("what") or re.sub(TRIGGER, "", line).strip(" ,.")
    return {"chip": f"Фоловап в Aleph «{what}» · {show(due)}", "run": {"kind": "python"},
            "fields": {"what": what, "due": due.strftime("%Y-%m-%dT%H:%M")}}


def run(fields):
    return _aleph.do({"type": "remind", "what": fields["what"], "due": fields["due"]})
