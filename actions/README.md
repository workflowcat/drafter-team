# Actions

One file per action. The engine loads every `*.py` here that does not start with `_`.

A file defines:

- `ID` - short name, e.g. `calendar.event`
- `TRIGGER` - a regex on the last line before the caret; cheap, runs on every pause in typing
- `extract(line, ask) -> dict | None` - fields from the line; `ask(prompt)` runs the warm model once and returns its text.
  Return `{"chip": "<exactly what will happen>", "run": {...}, "fields": {...}}` or None to stay quiet.
- `run(fields) -> str` - only for `run.kind == "python"`; returns the line shown after it ran.

App-side kinds (the Mac app does them, with its own permission): `eventkit.event` {title, start, minutes, notes},
`eventkit.reminder` {title, due}. Nothing runs until Andrii presses Tab on the chip. Never send a message: drafts only.
