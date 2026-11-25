"""Log rotation for data/, run by bench/nightly.sh (2026-11-13: engine.log had grown to 30 MB, app.log to 5 MB).

Two kinds of log, two ways:

- app.log: every line starts with an ISO time stamp, and the app opens the file for each line and closes it again
  (`log()` in app/Main.swift). The Settings page and the weekly page read the last 7 days, so the live file always
  keeps the last KEEP_DAYS (14) days. Older lines move to data/logs/app-<first day>_<last day>.log.gz. The live file
  is replaced by rename; a line some writer appended to the old file while we worked is read from the old file
  afterwards and added to the new one, so nothing is lost.

- engine.log, voice-engine.log: no time stamps, held open for the whole run by the engine processes (their stdout
  and stderr, opened by the app). Renaming would leave them writing into the archive, so these are copied and then
  truncated in place, once over MAX_MB. That is safe only when every process holding the file opened it with
  O_APPEND (lsof flag AP): their next write goes to the new end. A holder without O_APPEND would keep writing at
  its old offset and leave a hole of zeros, so then the file is left alone and the reason printed. The app opens
  them with O_APPEND since 2026-11-13; until that build runs, these two are skipped.

Archives older than ARCHIVE_WEEKS (8) weeks are deleted. Nothing outside data/logs/ is ever deleted.

    python3 scripts/rotate_logs.py [--data DIR] [--dry-run]
"""
import argparse, gzip, os, re, subprocess, sys, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEEP_DAYS = 14
ARCHIVE_WEEKS = 8
MAX_MB = 5
STAMP = re.compile(rb"^(\d{4}-\d{2}-\d{2})T")
ARCHIVE = re.compile(r"^(app|engine|voice-engine)-.+\.log\.gz$")


def free_name(folder: Path, stem: str) -> Path:
    p = folder / f"{stem}.log.gz"
    n = 2
    while p.exists():
        p = folder / f"{stem}-{n}.log.gz"; n += 1
    return p


def write_gz(path: Path, chunks):
    tmp = path.with_name(path.name + ".part")
    with gzip.open(tmp, "wb") as g:
        for c in chunks: g.write(c)
    os.replace(tmp, path)


def split_dated(data: bytes, cutoff: str):
    """Old part (lines before cutoff day) and the rest. A line without a stamp goes with the line before it.
    Stops at the first line on or after the cutoff: the file is in time order, and a stray older stamp later on
    (a clock change) stays in the live part rather than being moved out of order."""
    pos, last_old_day, first_day = 0, None, None
    for line in data.splitlines(keepends=True):
        m = STAMP.match(line)
        if m:
            day = m.group(1).decode()
            if day >= cutoff: break
            first_day = first_day or day
            last_old_day = day
        pos += len(line)
    if last_old_day is None: return b"", data, None, None
    if not data[:pos].endswith(b"\n"): return b"", data, None, None  # a half-written last line: wait for tomorrow
    return data[:pos], data[pos:], first_day, last_old_day


def rotate_dated(path: Path, logs: Path, now: datetime, dry: bool, settle: float = 1.0) -> str:
    if not path.exists(): return f"{path.name}: missing"
    cutoff = (now - timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
    with open(path, "rb") as old:
        data = old.read()
        head, rest, first, last = split_dated(data, cutoff)
        if not head: return f"{path.name}: nothing older than {cutoff}"
        if dry: return f"{path.name}: would move {len(head)} bytes ({first} to {last}), keep {len(rest)}"
        logs.mkdir(exist_ok=True)
        dest = free_name(logs, f"{path.stem}-{first}_{last}")
        write_gz(dest, [head])
        tmp = path.with_name(path.name + ".rotating")
        tmp.write_bytes(rest)
        os.replace(tmp, path)
        # a writer that opened the old file before the rename may still be writing to it: take what came after our read
        time.sleep(settle)
        late = old.read()
    if late:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try: os.write(fd, late)
        finally: os.close(fd)
    return f"{path.name}: moved {len(head)} bytes ({first} to {last}) to {dest.name}, kept {len(rest) + len(late)}"


def holders(path: Path):
    """(pid, command, flags) for every process holding the file open, from lsof (+fg: AP = O_APPEND)."""
    try:
        out = subprocess.run(["lsof", "-F", "pcfG", "+fg", "--", str(path)], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    found, pid, cmd = [], None, ""
    for line in out.splitlines():
        if line.startswith("p"): pid = line[1:]
        elif line.startswith("c"): cmd = line[1:]
        elif line.startswith("G"): found.append((pid, cmd, line[1:]))
    return found


def unsafe_writers(hold):
    # lsof file flags: "W" write-only, "RW" read-write (both write), "AP" append (2026-11-14, Argon 24: "RW" was missed)
    return [(p, c) for p, c, g in hold
            if {"W", "RW"} & set(g.split(";")[0].split(",")) and "AP" not in g.split(";")[0].split(",")]


def rotate_held(path: Path, logs: Path, now: datetime, dry: bool, max_mb: float = MAX_MB, hold=None) -> str:
    if not path.exists(): return f"{path.name}: missing"
    size = path.stat().st_size
    if size <= max_mb * 1_000_000: return f"{path.name}: {size / 1e6:.1f} MB, under {max_mb} MB"
    hold = holders(path) if hold is None else hold
    if hold is None: return f"{path.name}: lsof failed, left alone"
    bad = unsafe_writers(hold)
    if bad:
        who = ", ".join(f"{c} {p}" for p, c in bad)
        return f"{path.name}: {size / 1e6:.1f} MB, left alone: held open without O_APPEND by {who} (rotates after a rebuild and restart)"
    if dry: return f"{path.name}: would copy and truncate {size} bytes"
    logs.mkdir(exist_ok=True)
    dest = free_name(logs, f"{path.stem}-{now.strftime('%Y-%m-%d')}")
    copied = []
    with open(path, "rb") as f:
        for _ in range(3):
            chunk = f.read()
            copied.append(chunk)
            if os.fstat(f.fileno()).st_size == sum(map(len, copied)):
                os.truncate(path, 0)  # appending writers continue at the new end
                break
        else:
            return f"{path.name}: kept growing while copied, left alone"
    write_gz(dest, copied)
    return f"{path.name}: copied {sum(map(len, copied))} bytes to {dest.name} and truncated"


def prune(logs: Path, now: datetime, dry: bool) -> list:
    if not logs.is_dir(): return []
    limit = now.timestamp() - ARCHIVE_WEEKS * 7 * 86400
    gone = []
    for p in sorted(logs.iterdir()):
        if ARCHIVE.match(p.name) and p.stat().st_mtime < limit:
            if not dry: p.unlink()
            gone.append(p.name)
    return gone


def main(argv=None):
    a = argparse.ArgumentParser()
    a.add_argument("--data", default=str(ROOT / "data"))
    a.add_argument("--dry-run", action="store_true")
    o = a.parse_args(argv)
    data = Path(o.data); logs = data / "logs"
    now = datetime.now(timezone.utc)
    print("rotate logs", now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(" ", rotate_dated(data / "app.log", logs, now, o.dry_run))
    for name in ("engine.log", "voice-engine.log"):
        print(" ", rotate_held(data / name, logs, now, o.dry_run))
    for g in prune(logs, now, o.dry_run):
        print("  removed old archive" if not o.dry_run else "  would remove old archive", g)


if __name__ == "__main__":
    sys.exit(main())
