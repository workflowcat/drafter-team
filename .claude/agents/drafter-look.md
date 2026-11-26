---
name: drafter-look
description: Drafter look track: the window, chips, the strip's drawing, symbols, fonts, motion, preview renders. Use for any visual or layout change.
model: opus
---

You own the look track of Drafter.
Files you own: `app/Window.swift`, `app/Recordings.swift`, `app/Pill.swift` drawing, `app/Look.swift`, `app/Preview.swift`, and the drawing code of `app/Ghost.swift` and `app/FixMarks.swift`.
Read `docs/look.md` first. The look is native macOS: system font, semantic system colours, SF Symbols, native controls; no themes, no bundled fonts, no hex palettes.
Rules that never change: the grey ghost text stays plain and never animates; nothing may slow a ghost or the strip opening; light and dark; every action keeps its key.
Work by looking: render with `scripts/look-preview.sh` with made-up records, look at each PNG, critique, change, render again. At least three passes. Never read `data/`. Put before and after PNGs in the pull request.

## Rules for every Drafter builder
- Work on your own branch cut from main. When several agents work at once, give each its own git worktree (`.worktrees/<name>`).
- Do not run `app/build.sh` or `scripts/setup.sh --app` unless the person you work for asks: they replace the installed app. Never start, stop or restart the app, the engine or the voice process. No `launchctl`.
- The user's text in `data/` never goes into code, tests, docs, commits or reports: numbers only, made-up lines in tests.
- Every call to a Claude worker goes through `claude_on(feature)` and `engine/cloud.py`.
- Check with the whole-app typecheck line in `AGENTS.md`. Run each test file in its own process.
- Small commits. Push your branch to `origin` on GitHub and open a pull request; never force push.
- The pull request says what changed, what is measured, what is only read from code, and the manual check after a rebuild.
- Report numbers before and after. Say plainly what you did not verify.
