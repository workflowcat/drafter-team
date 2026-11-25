#!/bin/zsh
# Live insert check (insert audit, 23 November 2026; docs/inserts.md). Inserts made-up lines into its OWN test fields
# and prints target x kind -> ok / wrong text / nothing / stopped by guard, with timing.
#
# Usage (Andrii's Mac, after a release that has --insert-check; no restart needed, nothing is sent):
#   zsh scripts/insert_check.sh                     # TextEdit, Chrome and Safari, every kind
#   zsh scripts/insert_check.sh textedit            # one target: textedit | chrome | safari
#   INSERT_CHECK_SNIPPET=';xy' zsh scripts/insert_check.sh   # also the ; picker: a trigger whose FIRST row is a snippet
#                                                            # (never a lookup: a lookup row would go to Google)
# Where it acts: a TextEdit document and local HTML pages it writes into a fresh folder in $TMPDIR, each holding
# ⟦drafter-test⟧. Never Notes, never a messaging app. Each step is a second Drafter process (--insert-check) that
# acts only when that app is in front and the focused field holds the marker; it stops at once otherwise. It never
# presses Return, puts the clipboard back, closes its own documents (⌘W, title checked) and deletes the folder.
# Keep hands off the keyboard and mouse while it runs (about 2 min). Exit 0: every row ok; 1: a row not ok; 2: stopped.
set -u
APP="$HOME/Applications/Drafter.app"
BIN="$APP/Contents/MacOS/Drafter"
[[ -x $BIN ]] || { print "no Drafter at $APP"; exit 2 }
grep -q -a -- "--insert-check" "$BIN" || { print "the installed Drafter has no --insert-check yet: release opus/insert-audit first"; exit 2 }

DIR=$(mktemp -d "${TMPDIR:-/tmp/}drafter-insert-check-XXXXXX") || exit 2
MARK="⟦drafter-test⟧"
if (( $# )); then targets=("$@"); else targets=(textedit chrome safari); fi
kinds=(insert paste type voice-paste deck-text deck-picture picture ghost)
[[ -n ${INSERT_CHECK_SNIPPET:-} ]] && kinds+=(snippet)
lines=("The parcel comes on Tuesday" "Bring the blue folder" "Lunch moved to one" "Check the second shelf"
       "The van leaves at six" "Page four has the chart" "Photo of the whiteboard" "The plan for next week looks")
n=0; bad=0
rows=()

print -r -- "$MARK insert check - pick up the keys" > "$DIR/drafter-insert-check.txt"
for f in textarea editable input password; do
  cat > "$DIR/$f.html" <<EOF
<!doctype html><meta charset="utf-8"><title>$MARK insert check $f</title>
<body style="font:16px sans-serif">
<p>drafter-insert-check: made-up fields, nothing is sent.</p>
<textarea id="textarea" rows="4" cols="60">$MARK textarea </textarea><br>
<div id="editable" contenteditable="true" style="border:1px solid #888;min-height:3em;width:30em">$MARK editable </div>
<input id="input" size="60" value="$MARK input "><br>
<input id="password" type="password" value="x">
<script>
const el = document.getElementById("$f"); el.focus();
if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); r.collapse(false);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
else if (el.setSelectionRange) { el.setSelectionRange(el.value.length, el.value.length); }
document.querySelector("form")?.addEventListener("submit", e => e.preventDefault());
</script>
EOF
done

close_tabs() {   # only this run's own pages: a file:// tab whose title says "insert check" (a page it wrote)
  local app=$([[ $1 == chrome ]] && print "Google Chrome" || print Safari)
  local name=$([[ $1 == chrome ]] && print title || print name)
  osascript -e "tell application \"$app\"" -e "repeat with w in windows" \
    -e "set ts to (tabs of w whose $name contains \"insert check\")" -e "repeat with t in ts" \
    -e "if URL of t starts with \"file://\" then close t" -e "end repeat" -e "end repeat" -e "end tell" >/dev/null 2>&1
}

step() {   # bundle kind line -> prints the verdict and ms (the caller counts n: this runs in a subshell)
  local bundle=$1 kind=$2 line=${3:-}
  rm -f "$DIR/result-$n.txt"
  open -n -W -a "$APP" --args --insert-check "$DIR" "$bundle" "$kind" "$n" "$line"
  local r=$(cat "$DIR/result-$n.txt" 2>/dev/null || print "nothing written\t0")
  print -r -- "$r"
}

for t in $targets; do
  case $t in
    textedit) bundle=com.apple.TextEdit; fields=(document) ;;
    chrome)   bundle=com.google.Chrome;  fields=(textarea editable input password) ;;
    safari)   bundle=com.apple.Safari;   fields=(textarea editable input password) ;;
    *) print "unknown target $t"; continue ;;
  esac
  for f in $fields; do
    if [[ $t == textedit ]]; then open -a TextEdit "$DIR/drafter-insert-check.txt"
    elif [[ $t == chrome ]]; then open -a "Google Chrome" "file://$DIR/$f.html"
    else open -a Safari "file://$DIR/$f.html"; fi
    sleep 2.5
    case $t in   # bring the target to the front (Safari can open behind the app that was in front)
      textedit) osascript -e 'tell application "TextEdit" to activate' ;;
      chrome)   osascript -e 'tell application "Google Chrome" to activate' ;;
      safari)   osascript -e 'tell application "Safari" to activate' ;;
    esac
    sleep 1
    if [[ $f == password ]]; then
      n=$((n+1)); r=$(step $bundle guard-password); rows+=("$t/$f|guard-password|$r")
      [[ $r == ok* ]] || bad=$((bad+1))
    else
      [[ $t == textedit ]] && { n=$((n+1)); step $bundle end >/dev/null }
      i=0
      for k in $kinds; do
        i=$((i+1)); line=${lines[$(( (i-1) % ${#lines} + 1 ))]}
        [[ $k == snippet ]] && line=$INSERT_CHECK_SNIPPET
        [[ $k == picture && $f != editable ]] && continue   # a picture alone: only the rich box takes one
        n=$((n+1)); r=$(step $bundle $k "$line")
        rows+=("$t/$f|$k|$r")
        if [[ $r == stopped:* ]]; then
          print -r -- "STOPPED at $t/$f $k: ${r%%$'\t'*}"; for x in $rows; do print -r -- "  $x"; done
          if [[ $t == textedit ]]; then n=$((n+1)); step $bundle close >/dev/null; else close_tabs $t; fi; rm -rf "$DIR"; exit 2
        fi
        [[ $r == ok* || $r == "stopped by guard"* ]] || bad=$((bad+1))
        sleep 0.5
      done
    fi
    if [[ $t == textedit ]]; then n=$((n+1)); step $bundle close >/dev/null
    else close_tabs $t; fi   # ⌘W does not close a browser tab from the second process: close only its own file:// pages
    sleep 0.8
  done
done

printf "%-22s %-15s %-34s %s\n" "target" "kind" "result" "ms"
for r in $rows; do
  IFS='|' read -r tf k v <<< "$r"
  printf "%-22s %-15s %-34s %s\n" "$tf" "$k" "${v%%$'\t'*}" "${v##*$'\t'}"
done
print "rows: ${#rows}, not ok: $bad"
rm -rf "$DIR"
(( ${#rows} > 0 )) || { print "no rows ran"; exit 2 }
(( bad == 0 ))
