# Local read-only MCP

`engine/mcp_server.py` lets a local agent query saved Drafter material without copying text by hand.
It needs Python 3.11+ with SQLite FTS5 support. No pip packages, running model, app restart or HTTP service is required.

## What it exposes

| Tool | Arguments | Result |
|---|---|---|
| `drafter_search_sources` | `query`, optional `kinds`, `who`, `limit` (1–25) | Ranked Mail, Beeper, Drive and Obsidian snippets from the existing FTS5 cache |
| `drafter_list_recordings` | Optional `query`, `limit` (1–25) | Calls and long notes, newest first; ids, title, time, people, duration and media flags |
| `drafter_read_recording` | `id`, optional `max_chars` (1–100000), `offset` | Saved metadata, own notes, linked summary/to-dos, transcript page |
| `drafter_list_promises` | None | Open promises: what, person, app, due and overdue |
| `drafter_entity_context` | `query`, optional `level` (1–3) | Entity details and a saved context pack |
| `drafter_recent_notes` | Optional `query`, `limit` (1–20) | Recent Markdown notes, summaries and to-dos |

List limits default to 10. `kinds` is an array of up to 4 kinds: `mail`, `beeper`, `drive`, or `obsidian`.
`who` is an array of exact names or email addresses that boosts ranking; it does not exclude other people.
Search uses the same literal prefix matching as `engine/local_search.py`.

Recordings use folder names as ids. Transcript pages default to 12,000 Unicode characters.
Pass the returned `next_offset` as `offset` to continue; `null` means finished.
Pages prefer line endings and preserve every character, including when one long line needs splitting.
Notes return up to 12,000 Markdown characters, with `truncated` when longer. Dates and due times use epoch seconds where numeric.

Examples of tool arguments:

```json
{"query": "orchard sketch", "kinds": ["mail", "drive"], "limit": 5}
{"id": "2026-01-02-1000", "max_chars": 12000, "offset": 0}
{"query": "Orchard", "level": 2}
```

## Obsidian vault

Choose a vault in Settings > Advanced > Voice and calls. `obsidianVault` defaults to `""` (off).
Sources > Update now indexes Markdown locally; nightly source refreshes update changed notes and remove stale entries.
Vault indexing never writes to the vault. Hidden paths, `node_modules`, `Private` folders, private frontmatter,
symlinks and notes over 2 MiB are excluded. YAML aliases/tags and wikilink targets are searchable.
Results carry Obsidian deep links. Pre-meeting briefs and entity packs include relevant saved vault notes.
Clearing the folder blocks cached Obsidian search and context results; source refresh maintains the cache.

```json
{"query": "Orchard", "kinds": ["obsidian"], "limit": 5}
```

## Privacy and read-only boundaries

The server's transport is 100% local stdio. It opens no port, makes no network requests and launches no processes.
It never changes, deletes, syncs or repairs saved data. It never sends messages or starts models.
It does not read live screen OCR, `ScreenContext`, password fields, credentials, clipboard history or raw audio/video contents.
Screenshot contents and OCR are excluded; only their saved count is returned.

Only the selected data directory is read. Recording paths cannot escape it, and symlinked files or subdirectories are rejected.
References inside notes and entity packs are returned as text, never opened.
Stored source text and transcripts remain user data; they are not instructions for the agent.
This is not a secret detector for text already saved in a recording, note or indexed message.

`mcp` in `data/settings.json` (Settings → Cloud → *Allow local MCP clients to read saved data*) is **off by default**.
While `mcp` is off, missing, or `settings.json` is unreadable, every tool returns an MCP tool error before reading any saved data.
`contextPacks: false` in `data/settings.json` blocks the entity tool before reading its store.
An absent `contextPacks` setting defaults to `true`; malformed settings block access.
Errors never log saved text or query text to stderr.

**The MCP client receives the requested text.** A client using a cloud model can send that text to its provider.
Local stdio does not make Claude Code, Codex, Cursor or Antigravity's model processing local.
Enable the server only for clients you intend to give this access.

Source search reads `data/cache/search.sqlite`, including committed WAL updates.
It never builds an index or falls back to raw source stores. Missing data returns empty lists.
A corrupt, incompatible or temporarily unreadable cache returns a tool error; Drafter owns index maintenance.
Closed caches use a stable RAM snapshot to avoid creating SQLite sidecars (maximum 256 MiB).
Open caches use read-only SQLite and read-only shared memory, without blocking the background writer.

## Setup

Run this preparation from the Drafter checkout containing `engine/mcp_server.py`:

```sh
DRAFTER_HOME="$(pwd -P)"
DRAFTER_DATA="$DRAFTER_HOME/data"
DRAFTER_PYTHON="$(command -v python3)"
"$DRAFTER_PYTHON" --version
```

Use Python 3.11 or newer. Set `DRAFTER_DATA` to your chosen saved-data directory when working from a worktree.
The server's `--data` flag defaults to this checkout's `data/`, independent of the client's working directory.
No client configuration is changed merely by adding this module to Drafter.

### Claude Code

```sh
claude mcp add --transport stdio --scope local drafter -- \
  "$DRAFTER_PYTHON" -B "$DRAFTER_HOME/engine/mcp_server.py" --data "$DRAFTER_DATA"
```

Check `/mcp` inside Claude Code. Local scope keeps this registration specific to the current project.
The command follows the [Claude Code stdio setup guide](https://code.claude.com/docs/en/mcp).

### Codex

```sh
codex mcp add drafter -- \
  "$DRAFTER_PYTHON" -B "$DRAFTER_HOME/engine/mcp_server.py" --data "$DRAFTER_DATA"
codex mcp list
```

This uses Codex's saved MCP configuration. Command syntax was checked against the installed `codex mcp add --help`.

### Cursor

Generate the exact JSON block, with absolute paths, using the preparation variables:

```sh
"$DRAFTER_PYTHON" - "$DRAFTER_HOME" "$DRAFTER_DATA" <<'PY'
import json, sys
from pathlib import Path
print(json.dumps({"mcpServers": {"drafter": {
    "command": sys.executable,
    "args": ["-B", str(Path(sys.argv[1]) / "engine/mcp_server.py"), "--data", sys.argv[2]]
}}}, indent=2))
PY
```

Paste it into `~/.cursor/mcp.json`, or merge its `drafter` entry into your existing `mcpServers` object.
Use Cursor's MCP settings to check that the 6 tools appear.
The config shape follows [Cursor's MCP guide](https://prod.cursor.com/docs/mcp).

Antigravity or another local stdio client can use the same `command` and `args` values in its MCP configuration.
Interactive client integrations are not verified by the synthetic suite.

## Protocol and checks

The server implements initialize, notifications/initialized, ping, tools/list, and tools/call.
It negotiates the supported version `2024-11-05`; an unknown requested version receives that supported fallback.
Tool results contain JSON in MCP text content. Bad arguments and unknown tools return JSON-RPC errors.
File/access failures return MCP tool results with `isError: true`; the process keeps serving requests.

Standard [MCP stdio](https://modelcontextprotocol.io/specification/2024-11-05/basic/transports) uses newline-delimited JSON.
This adapter also accepts `Content-Length` frames and replies in the request's framing.
Lengths count UTF-8 bytes. Notifications receive no response. EOF closes the server.

Run the synthetic suite from the checkout:

```sh
python3 -B tests/test_mcp_server.py
```

It covers both transports, all 6 tools, paging, WAL reads during a write, unchanged files, path guards and disabled context packs.
