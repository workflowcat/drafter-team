# Actions

One file per action. The engine loads every `*.py` here that does not start with `_`.

A file defines:

- `ID` - short name, e.g. `calendar.event`
- `TRIGGER` - a regex on the last line before the caret; cheap, runs on every pause in typing
- `extract(line, ask) -> dict | None` - fields from the line; `ask(prompt)` runs the warm model once and returns its text.
  Return `{"chip": "<exactly what will happen>", "run": {...}, "fields": {...}}` or None to stay quiet.
- `run(fields) -> str` - only for `run.kind == "python"`; returns the line shown after it ran.

Shipped: `calendar_event.py` and `reminder.py` (the app adds them through EventKit) and `vault_note.py` (a Markdown
file in your notes folder; only when the `vault` integration is on). `NEEDS` names the integrations an action needs
(`engine/integrations.py`); the chip is offered only when each one is on and answers, so an action that needs one is off
by default. `_claude.py` helps an action of your own run the signed-in `claude` CLI with a skill you name, in the
background; keep such actions in your own fork or folder.

App-side kinds (the Mac app does them, with its own permission): `eventkit.event` {title, start, minutes, notes},
`eventkit.reminder` {title, due}. Nothing runs until the user presses Tab on the chip. Never send a message: drafts only.
