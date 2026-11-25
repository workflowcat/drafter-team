"""Opt-in, read-only Markdown source. No dependencies, network, or vault writes.

Directory descriptors and O_NOFOLLOW keep traversal inside the selected vault.
Only cached public notes enter search/context; Private folders are never opened.
"""
import json
import os
from pathlib import Path
import re
import stat
import uuid
from urllib.parse import quote

DATA = Path(__file__).resolve().parent.parent / "data"
MAX_BYTES = 2 * 1024 * 1024
SKIP = {"node_modules", "private"}
WIKI = re.compile(r"!?\[\[([^\]]+)\]\]")


def vault_path(data_dir=None):
    """Empty, invalid, inaccessible or symlinked roots disable the source."""
    try:
        settings = _read_json(Path(data_dir or DATA) / "settings.json")
        value = settings.get("obsidianVault", "")
        if not isinstance(value, str) or not value.strip(): return None
        root = Path(value).expanduser().absolute()
        if ".." in root.parts or root.is_symlink() or not root.is_dir(): return None
        if root.name.casefold() == "private" or any(p.name.casefold() == "private" and str(p) != "/private" for p in root.parents): return None
        # Also reject a root reached through a user-created symlink ancestor.
        if any(p.is_symlink() for p in root.parents): return None
        if Path(data_dir or DATA).absolute().is_relative_to(root): return None
        return root
    except (OSError, ValueError, AttributeError):
        return None


def enabled(data_dir=None):
    data = Path(data_dir or DATA)
    if vault_path(data) is None: return False
    try:
        switch = _read_json(data / "sources.json").get("obsidian", {})
        return switch.get("enabled", True) is not False
    except FileNotFoundError:
        return True
    except (OSError, ValueError, AttributeError):
        return False


def _scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        if value[0] == '"':
            try: return json.loads(value)
            except ValueError: pass
        return value[1:-1].replace("''", "'")
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def _list(value):
    value = re.sub(r"\]\s+#.*$", "]", value.strip())
    if value.startswith("[") and value.endswith("]"):
        # YAML's small string-list subset: quoted commas, single/double quotes.
        parts = re.findall(r'''\s*("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,]+)\s*(?:,|$)''', value[1:-1])
        return [_scalar(v) for v in parts if _scalar(v)]
    return [_scalar(value)] if _scalar(value) else []


def frontmatter(text):
    text = text.lstrip("\ufeff").replace("\r\n", "\n")
    match = re.match(r"\A---[ \t]*\n(.*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)", text, re.S)
    if not match:
        return ({"private": ["true"]}, "") if text.startswith("---\n") else ({}, text)
    fields, key = {}, None
    for line in match[1].splitlines():
        item = re.match(r"^\s*-\s+(.+)$", line)
        field = re.match(r"^([\w-]+):\s*(.*)$", line)
        if field:
            key = field[1].lower()
            fields[key] = _list(field[2])
        elif item and key:
            fields[key].append(_scalar(item[1]))
        elif line.strip() and not line.lstrip().startswith("#"):
            key = None
    return fields, text[match.end():]


def parse_note(text, relative, root, mtime):
    fm, body = frontmatter(text)
    tags = [t.lstrip("#") for t in fm.get("tags", []) if t.lstrip("#")]
    if (any(v.casefold() in ("true", "yes") for v in fm.get("private", []))
            or any(v.casefold() == "private" for k in ("scope", "visibility") for v in fm.get(k, []))
            or "private" in [t.casefold() for t in tags]): return None
    aliases = list(dict.fromkeys(fm.get("aliases", [])))
    links = []
    def wiki(m):
        target, _, alias = m[1].partition("|")
        note, _, heading = target.partition("#")
        note = note.strip()
        if note: links.append(note)
        return " ".join(x for x in (note, heading.strip(), alias.strip()) if x)
    clean = WIKI.sub(wiki, body)
    tags += re.findall(r"(?<![\w/#])#([^\W\d][\w/-]*)", body, re.UNICODE)
    tags = list(dict.fromkeys(tags))
    heading = re.search(r"^#[ \t]+(.+?)[ \t]*#*[ \t]*$", body, re.M)
    title = WIKI.sub(wiki, heading[1]).strip() if heading else Path(relative).stem
    clean = re.sub(r"(?m)^\s{0,3}#{1,6}\s+", "", clean)
    clean = re.sub(r"(?<![\w/#])#(?=[^\W\d])", "", clean)
    clean = re.sub(r"\n{3,}", "\n\n", clean).strip()
    return {"id": "obsidian:" + str(Path(relative).with_suffix("")).replace(os.sep, "/"),
            "src": "obsidian", "t": mtime, "title": title,
            "text": "\n".join([clean, *aliases, *tags]).strip(), "aliases": aliases, "tags": tags,
            "links": list(dict.fromkeys(links)), "who": [], "mine": False, "files": [],
            "url": "obsidian://open?vault=" + quote(root.name, safe="") + "&file=" + quote(relative, safe="")}


def _open_directory(path):
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in Path(path).absolute().parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        return fd
    except OSError:
        os.close(fd)
        raise


def _read_json(path):
    parent = _open_directory(path.parent)
    try: fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally: os.close(parent)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise ValueError("Not a regular file")
        return json.load(stream)


def _write_cache(data, rows):
    """Write only through held data directory descriptors, never through vault paths."""
    parent = _open_directory(data)
    try:
        try: os.mkdir("sources", mode=0o700, dir_fd=parent)
        except FileExistsError: pass
        folder = os.open("sources", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    finally: os.close(parent)
    temp = ".obsidian-" + uuid.uuid4().hex
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=folder)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            for _, row in sorted(rows.items()): stream.write(json.dumps(row, ensure_ascii=False) + "\n")
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temp, "obsidian.jsonl", src_dir_fd=folder, dst_dir_fd=folder)
    finally:
        try: os.unlink(temp, dir_fd=folder)
        except FileNotFoundError: pass
        os.close(folder)


def _read_cache(path):
    """No symlink traversal, including a cache directory swapped during a read."""
    rows = {}
    try:
        parent = _open_directory(path.parent)
        try: fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        finally: os.close(parent)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): return {}
            for line in stream:
                try: row = json.loads(line)
                except ValueError: continue
                if isinstance(row, dict) and row.get("id"): rows[row["id"]] = row
    except (OSError, UnicodeError): pass
    return rows


def _walk(fd, prefix=""):
    with os.scandir(fd) as scan:
        entries = sorted(scan, key=lambda e: e.name)
    for entry in entries:
        if entry.name.startswith(".") or entry.name.casefold() in SKIP: continue
        rel = prefix + entry.name
        try:
            info = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try: yield from _walk(child, rel + "/")
                finally: os.close(child)
            elif stat.S_ISREG(info.st_mode) and entry.name.lower().endswith(".md") and info.st_size <= MAX_BYTES:
                yield fd, entry.name, rel, info
        except OSError:
            continue


def sync(data_dir=None):
    """Reparse changed notes only; atomic cache replacement removes stale rows.

    Off is a no-op. Cached rows are gated by settings at every read as well.
    """
    data = Path(data_dir or DATA)
    root = vault_path(data)
    if root is None or not enabled(data): return 0
    path = data / "sources/obsidian.jsonl"
    old, rows, changed = _read_cache(path), {}, 0
    fd = _open_directory(root)
    try:
        for parent, name, relative, info in _walk(fd):
            ident = "obsidian:" + relative[:-3]
            stamp = [info.st_mtime_ns, info.st_size, info.st_ino, info.st_ctime_ns]
            cached = old.get(ident)
            if cached and cached.get("_stamp") == stamp and cached.get("_vault") == str(root):
                rows[ident] = cached; continue
            try:
                note_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                with os.fdopen(note_fd, "rb") as stream:
                    before = os.fstat(stream.fileno())
                    if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES: continue
                    raw = stream.read(MAX_BYTES + 1)
                    after = os.fstat(stream.fileno())
                # compare what a write changes, not the whole stat: reading moves st_atime, which dropped notes (Gemini review, 25 Nov)
                same = lambda a, b: (a.st_mtime_ns, a.st_size, a.st_ino, a.st_ctime_ns) == (b.st_mtime_ns, b.st_size, b.st_ino, b.st_ctime_ns)
                if len(raw) > MAX_BYTES or not same(before, after) or before.st_ino != info.st_ino: continue
                row = parse_note(raw.decode("utf-8", "replace"), relative, root, info.st_mtime)
                if row: rows[ident] = dict(row, _stamp=stamp, _vault=str(root))
                changed += 1
            except OSError:
                continue
    finally:
        os.close(fd)
    if rows != old:
        _write_cache(data, rows)
    return changed + len(old.keys() - rows.keys())


def cached_notes(data_dir=None):
    data = Path(data_dir or DATA)
    if not enabled(data): return []
    path = data / "sources/obsidian.jsonl"
    if path.is_symlink() or any(p.is_symlink() for p in path.parents): return []
    root = str(vault_path(data))
    return [r for r in _read_cache(path).values() if r.get("_vault") == root]


class NoteIndex:
    """Exact title/alias/wiki surfaces, indexed once for a batch of entity packs."""
    def __init__(self, rows):
        self.by_name = {}
        for row in rows:
            surfaces = {self.fold(n) for n in [row.get("title", ""), *row.get("aliases", []), *row.get("links", [])]}
            surfaces |= {s.rsplit("/", 1)[-1] for s in surfaces}
            for surface in surfaces:
                if surface: self.by_name.setdefault(surface, []).append(row)

    @staticmethod
    def fold(value): return " ".join(str(value).casefold().split())

    def match(self, names, limit=3):
        found = {}
        for name in names:
            if not isinstance(name, str) or len(name.strip()) < 2: continue
            for row in self.by_name.get(self.fold(name), []): found[row["id"]] = row
        return sorted(found.values(), key=lambda r: (-r.get("t", 0), r["id"]))[:limit]


class NoteCache:
    """Per-reader cache: metadata changes invalidate it; clearing the setting blocks it immediately."""
    def __init__(self, data_dir):
        self.data = Path(data_dir)
        self.stamp, self.index = None, NoteIndex([])

    def read(self):
        root = vault_path(self.data) if enabled(self.data) else None
        try:
            st = (self.data / "sources/obsidian.jsonl").stat()
            stamp = (str(root), st.st_mtime_ns, st.st_size, st.st_ino) if root else None
        except OSError: stamp = None
        if stamp is None:
            self.stamp, self.index = None, NoteIndex([])
        elif stamp != self.stamp:
            self.index = NoteIndex(cached_notes(self.data)); self.stamp = stamp
        return self.index


def matching_notes(names, rows, limit=3):
    index = rows if isinstance(rows, NoteIndex) else NoteIndex(rows)
    return index.match(names, limit)
