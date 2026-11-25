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
  12 pt floating panels.
- **Symbols:** SF Symbols. The app's own names (`bookmark`, `waves`, `verified`) map to symbols in `Native.symbols`.
- **Grey text stays plain:** the field's own font, a lighter shade, no fade, no animation.
- **The strip stays black** in both appearances (it merges with the notch) and draws its words in the dark
  label colours; never the faintest grey on it (`tests/strip_rules.swift` checks contrast on black).

## Floating panels (caret-cozy round, 23 November 2026)

- One ground: the card colour, a 0.5 pt hairline edge, 12 pt corners, one soft shadow (`Panel.ground`).
- 12 pt inside, 8 pt between, 13 pt words, 12 pt hints.
- Rows as in the journal: the kind's symbol in its colour, one line, app and time quiet at the right; the chosen
  row a soft accent lift with 8 pt corners (`Panel.row`).
- Keys as small key caps everywhere: 20 pt high, 5 pt corners, a soft fill and a hairline (`Panel.keycap`).
- Buttons bordered, with their key cap; the main one filled with the accent (`Panel.button`). Tips use the ground.
- SwiftUI: `PanelKeyCap`, `PanelButton`, `.panelGround()` (the popover material).

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
- **Editing:** a real multi-line field in place, Save (⌘↵, prominent) and Cancel (esc) under it.
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
