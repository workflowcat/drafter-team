# Building with agents

Most of Drafter was built by coding agents, with one lead agent that briefs, checks, merges and releases. This page
describes that way of working and two mistakes worth learning from.

## Tracks and roles

Six saved roles in `.claude/agents/` each own one track and its files.

| Role | Track | Owns, for example |
|---|---|---|
| `drafter-typing` | Grey text speed and accuracy | `engine/model.py`, `engine/gatecore.py`, `engine/words.py`, `bench/`, `app/Keys.swift` |
| `drafter-voice` | Takes, the strip's logic, calls, transcripts | `engine/voice.py`, `app/Voice.swift`, `app/Call.swift` |
| `drafter-look` | Window, chips, strip drawing, marks, previews | `app/Look.swift`, `app/Window.swift`, `app/Preview.swift` |
| `drafter-release` | Setup, config split, licences, private-data scrub | `scripts/`, `drafter.local.example.json` |
| `drafter-efficiency` | Memory, CPU, battery, startup time | Resource use across all three processes |
| `drafter-quality` | Tests, the replay, review findings, dead code | `tests/`, `bench/review.py`, `bench/week.py` |

Each role file states a goal that never changes. For typing it is: first grey text sooner, and the first word right
more often. Every role file ends with the same rules for all builders.

## Worktrees and who builds

- Each builder works in its own git worktree, `.worktrees/<name>`, on a branch `opus/<name>` cut from main.
- Builders never edit the main checkout, because the running app is built from it.
- Builders never run `app/build.sh` and never start, stop or restart the app or its engines.
- **The lead builds and releases.** Builders make small commits. They do not push or merge.

This keeps one person (or agent) responsible for what runs on the Mac. A builder cannot break the live app.

## How a round runs

```mermaid
flowchart LR
    A[brief] --> B[build in a worktree]
    B --> C[round notes]
    C --> D[review by another model]
    D --> E[verify each finding]
    E --> F[fix and test]
    F --> G[lead merges, builds, releases]
```

1. **Brief.** The lead writes the goal, the files in scope, what is already rejected, and the numbers to report.
2. **Build.** The builder works in its worktree and runs the whole-app typecheck and each test file.
3. **Notes.** The builder writes round notes: what changed, what was measured, what was only read from code, and
   the manual check to do after a rebuild. It says plainly what it did not verify.
4. **Review.** A different model reads the round's commits and lists findings.
5. **Verify.** Each finding is checked against the code before anyone fixes it. The verdict is REAL, NOT REAL, or
   REAL BUT DIFFERENT. A real finding gets a failing test first, where one can be written.
6. **Merge.** The lead merges, builds from the main checkout, restarts the app and does the live checks.

## Measure first

A typing change is kept only with numbers before and after, on the same held-out lines:

- first word right at first display;
- letters saved;
- wrong offers per 1,000 letters;
- time to the first grey text.

All typing benches score through one replay, `bench/measure.py`. Fitting uses the earlier half of the held-out
lines, by date, and the score uses the later half. Before this rule, a change could look good on the lines it
was tuned on. Settings that a bench cannot judge are listed as "believed, not measured" in the round notes.

Some ideas lost on numbers and were dropped: wider phrase memory, a bigger model, a layer trained on every source.
[Training](training.md) lists them.

## Two mistakes worth knowing

**Five rounds in one day.** Five agents each finished a round on the same day. Each passed its own tests. A later
outside review of those rounds listed 25 findings. When each was checked against the code, 20 needed a fix: data
races, a recording that could lose the other side, a ghost left on screen after its words changed, a fast double
Tab that put a word in twice. The lesson: parallel rounds need a review pass of their own before release, and
"tests pass" is not the same as "reviewed".

**A setting checked in the app but not in the engine.** The app checked the Claude switches before it sent a
request. Some engine routes did not check them again. One route started Claude workers on every field focus with
only one of its two switches checked. Another had no check at all. The fix was one table, `engine/cloud.py`,
that names the switch owning each feature that sends text to Claude, and one engine function,
`server.claude_on(feature)`, that checks it. `tests/test_cloud_gate.py` walks every Claude call site in `engine/`
and fails when one is missing from the table or skips the check. The lesson: a privacy rule belongs where the data
leaves, not only in the user interface.
