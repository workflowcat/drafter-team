# Look

Drafter looks like a macOS app. No themes, no bundled fonts or art. Light, dark and your accent colour follow
macOS by themselves. Colours, type and symbols are in `app/Look.swift`; the floating-panel pieces (ground, key caps, buttons, rows,
tips) in `app/Panel.swift`.

## The rules

- **Font:** the system font (SF Pro) for words, `.monospacedDigitSystemFont` where numbers must line up
  (times, lengths, counts, keys). Sizes as macOS uses them: 13 pt body.
- **Colours:** semantic system colours only. Words `labelColor`, second words `secondaryLabelColor`, hints
  `tertiaryLabelColor`, hairlines `separatorColor`, grounds `windowBackgroundColor` and `controlBackgroundColor`,
  the accent `controlAccentColor`; states `systemRed` (live, recording), `systemGreen` (done), `systemOrange` (a fix).
  No hex palettes in the interface.
- **Controls:** native: the system switch, pickers and buttons. Rounded corners: 4-5 pt keys and tags, 6-8 pt controls,
  18 pt floating glass.
- **Symbols:** SF Symbols. The app's own names (`bookmark`, `waves`, `verified`) map to symbols in `Native.symbols`.
- **Grey text stays plain:** the field's own font, a lighter shade, no fade, no animation.
- **The strip stays black** in both appearances (it merges with the notch) and draws its words in the dark
  label colours; never the faintest grey on it (`tests/strip_rules.swift` checks contrast on black).

## Glossary

The words the window, Help and these docs use, one meaning each:

- **Take:** one dictation, from Right Option to the words going in at the caret.
- **Recording:** a call or a long spoken note (⇧ Right Option). Its audio, transcript and notes stay together.
- **Meeting notes:** a recording started for a calendar event, from the strip's offer.
- **The stream:** the window's main view: what you typed, said, copied and recorded, by day.
- **Snippets:** short cues like `;mail` that put in a longer text (the Shortcuts page, ⌘J).
- **Copy for agent:** puts a line on the clipboard that points a coding agent at the open recording (⇧⌘A).
- **Share notes:** puts a recording's notes on the clipboard, for you to paste where you want.
- **To do:** the follow-ups found in a recording's notes. Written "To do", never "To-dos".

## Rebuild B: what floats is glass (26 November 2026)

Drafter floats over your work and fades when you are done. Shared pieces in `app/Panel.swift`, tokens in `app/Look.swift`.

- **Glass:** a floating panel sits in a `GlassHost` (the popover material, the app below blurred) and its ground
  draws a light tint, a bright rim and a 0.5 pt hairline over it (`Panel.ground(..., glass: true)`). 18 pt corners.
  The one soft shadow is drawn outside the card only. SwiftUI: `.glassCard()` and `.panelGround()`.
- **One key pill:** the keys of a panel sit in one near-black pill, each a faint white cap with its word; the main
  action is the pill's blue end with its own cap (`Panel.pill`, SwiftUI `HudPill`). The blue end is `systemBlue`
  even with a graphite accent, so "do it" always reads. Footers with loose key caps are gone.
- **No page titles:** a page names itself with a small glass chip (`PlaceChip`, inside `PageHeader`), its one muted
  line after it. Every page is on the window's icon rail at the left (`app/WindowRail.swift`); the ⋯ menu keeps them
  too, with their keys.
- **The chosen line lifts:** the open row in the stream and the current Welcome step become a near-white card with
  the float shadow (`Native.lift`); done steps fade, the rest wait folded.
- **Motion:** a panel fades in and rises 6 pt in 80 ms (`Panel.appear`, SwiftUI `.riseIn`); nothing moves with
  Reduce Motion on.
- **Live stays black:** the strip and the recording notch keep the black housing.
- Inside a panel: 12 pt in, 8 pt between, 13 pt words, rows as in the journal (`Panel.row`), buttons bordered with
  their key cap (`Panel.button`). Light key caps (`Panel.keycap`, `PanelKeyCap`) stay for keys named inside text.

## Kinds

`Kind` in `app/Look.swift` gives each kind of offer one symbol and one colour, the same at the caret, in the strip
and in the window: items (snippet, person, fact, voice, link, next message) in the accent colour, actions (action,
lookup, translate, rework) purple, a fix orange.

## The journal stream

The journal window is one calm column, at most 680 pt, search first (`app/Stream.swift`, rules
`app/StreamRules.swift`; zoom and topics in `app/StreamZoomViews.swift` and `app/StreamTopicViews.swift`).

- **Top:** the big search field with the scope menu at its start; the bar holds only Record and ⋯. Record is a
  bordered menu button; while recording it shows the title, the time, a two-bar level meter, Pause and Stop.
- **Rows:** one line each, 34 pt, one mark at the start (the kind symbol, or a picture's thumbnail in the same
  30 × 20 slot), then the text, the app, the time. Day headings while the stream is in time order; "Best matches"
  with the date on each row while words are searched.
- **An open row:** standard bordered buttons at normal size, each with its key in quieter text after the word. One
  is prominent: Insert for text, Play for audio. Pin and Delete are labelled. The rest sit in More.
- **Player:** Play (prominent), back 10 s, the time, a scrubber, the length, forward 10 s, speed. The line playing
  is marked with the selection colour; a click on a line plays from there.
- **Editing:** a real multi-line field in place, Save (⌘↵, prominent) and Cancel (Esc) under it.
- **Foot:** one line: the notice with Undo, the picked rows with Combine, or what the keys do here.
- No toolbar of icons. Controls show on the open row or on hover only.

## Motion

- A chip fades in over 80 ms. Grey text has no fade.
- When a take lands, the `verified` mark draws in from left to right.
- Reduce Motion turns the motion off.

## Preview renders

The app draws its own screens with made-up data, without a microphone, an engine or your files
(`app/Preview.swift`, `UIShots.run`).

```sh
zsh scripts/look-preview.sh /tmp/drafter-look
```

The script builds a scratch copy in a temp folder whose home is an empty temp folder, renders `<out>/light` and
`<out>/dark` with `--ui-preview <dir>` (and `--dark`), then deletes the copy. It never installs or starts the app.
