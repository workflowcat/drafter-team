"""Old call audio and screen video go to the Trash once the transcript exists. Run by bench/nightly.sh (2026-11-14).

A recording folder under data/calls/ keeps its audio (*.wav) and opt-in screen video (screen.mp4) for KEEP_DAYS (14)
days. After that, when the folder holds a transcript.txt of at least MIN_TRANSCRIPT bytes and no `.unread` mark, those
media files move to ~/.Trash/drafter-audio-<day>/<folder>/. The transcript, notes, screenshots and meta stay. Nothing
is deleted: the Trash is the way back for a transcript that turns out bad. A folder without a transcript keeps its
media. Hidden temporary video files (`.screen-*.mp4`) left behind by a crash are swept after ORPHAN_HOURS (24 h).

    python3 scripts/prune_audio.py [--data DIR] [--trash DIR] [--days N] [--dry-run]
"""
import argparse, shutil, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEEP_DAYS = 14
ORPHAN_HOURS = 24
MIN_TRANSCRIPT = 200


def due(calls: Path, now: float, days: int = KEEP_DAYS) -> list:
    """Media files (*.wav, screen.mp4) that may go: old enough, in a folder with a real transcript and no unread mark."""
    out = []
    if not calls.is_dir(): return out
    for folder in sorted(p for p in calls.iterdir() if p.is_dir()):
        t = folder / "transcript.txt"
        if not t.is_file() or t.stat().st_size < MIN_TRANSCRIPT or (folder / ".unread").exists(): continue
        candidates = list(sorted(folder.glob("*.wav")))
        video = folder / "screen.mp4"
        if video.is_file(): candidates.append(video)
        for media in candidates:
            if now - media.stat().st_mtime > days * 86400: out.append(media)
    return out


def orphans(calls: Path, now: float, hours: float = ORPHAN_HOURS) -> list:
    """Hidden .screen-*.mp4 files left behind by an interrupted video finish, older than `hours`."""
    out = []
    if not calls.is_dir(): return out
    cutoff = hours * 3600
    for folder in sorted(p for p in calls.iterdir() if p.is_dir()):
        for pending in sorted(folder.glob(".screen-*.mp4")):
            if pending.is_file() and now - pending.stat().st_mtime > cutoff:
                out.append(pending)
    return out


def move(files: list, trash: Path, dry: bool) -> int:
    size = 0
    for f in files:
        size += f.stat().st_size
        if dry: continue
        dest = trash / f.parent.name
        dest.mkdir(parents=True, exist_ok=True)
        shutil.move(str(f), str(dest / f.name))
    return size


def sweep(files: list, dry: bool) -> int:
    size = 0
    for f in files:
        try:
            size += f.stat().st_size
            if not dry: f.unlink(missing_ok=True)
        except OSError:
            pass
    return size


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=ROOT / "data")
    ap.add_argument("--trash", type=Path, default=Path.home() / ".Trash" / f"drafter-audio-{time.strftime('%Y-%m-%d')}")
    ap.add_argument("--days", type=int, default=KEEP_DAYS)
    ap.add_argument("--dry-run", action="store_true")
    o = ap.parse_args()
    now = time.time()
    files = due(o.data / "calls", now, o.days)
    size = move(files, o.trash, o.dry_run)
    stale = orphans(o.data / "calls", now)
    stale_size = sweep(stale, o.dry_run)
    print(f"prune_audio: {len(files)} media files, {size / 1e6:.0f} MB {'would go' if o.dry_run else 'moved'} to the Trash"
          + (f"; {len(stale)} orphaned temp videos ({stale_size / 1e6:.1f} MB)" if stale else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
