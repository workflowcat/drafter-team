"""Synthetic temporary vaults only. No live data, remote tools, models or app access."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import obsidian
import sources
from local_search import LocalSearchIndex
import entities
import prep


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.data = self.root / "data"; self.data.mkdir()
        self.vault = self.root / "Orchard & Station"; self.vault.mkdir()
        self.configure()

    def configure(self, **extra):
        (self.data / "settings.json").write_text(json.dumps({"obsidianVault": str(self.vault), **extra}))

    def note(self, path="Orchard.md", text="# Orchard\nReview [[Demo Guest]]. #planning"):
        file = self.vault / path; file.parent.mkdir(parents=True, exist_ok=True); file.write_text(text)
        return file

    def index(self):
        obsidian.sync(self.data)
        index = LocalSearchIndex(data_dir=self.data)
        self.addCleanup(index.close)
        self.assertNotIn("error", index.sync())
        return index

    def test_parse_frontmatter_lists_wikilinks_tags_and_encoding(self):
        self.note("Plans/Station #1.md", '''---
aliases: [Orchard, "Demo, Guest", 'Station alias']
tags:
  - planning
  - '#weekly'
ignored: hiddenvalue
---
# Station plan
## Next steps
Review [[Demo Guest|Guest]] and [[Orchard#Budget]] plus [[Plans/Station]]. #local/tag
''')
        obsidian.sync(self.data)
        row = obsidian.cached_notes(self.data)[0]
        self.assertEqual(row["id"], "obsidian:Plans/Station #1")
        self.assertEqual(row["src"], "obsidian")
        self.assertEqual(row["title"], "Station plan")
        self.assertEqual(row["aliases"], ["Orchard", "Demo, Guest", "Station alias"])
        self.assertEqual(row["tags"], ["planning", "weekly", "local/tag"])
        self.assertEqual(row["links"], ["Demo Guest", "Orchard", "Plans/Station"])
        for text in ("Next steps", "Budget", "Guest", "Station alias", "weekly"): self.assertIn(text, row["text"])
        for text in ("ignored:", "hiddenvalue", "[[", "---"): self.assertNotIn(text, row["text"])
        self.assertEqual(row["who"], [])
        self.assertEqual(parse_qs(urlsplit(row["url"]).query), {"vault": [self.vault.name], "file": ["Plans/Station #1.md"]})
        self.assertIn("%26", row["url"]); self.assertIn("%2F", row["url"]); self.assertIn("%23", row["url"])
        self.assertGreater(row["t"], 0)

    def test_alias_bullets_inline_tags_and_filename_fallback(self):
        row = obsidian.parse_note("---\naliases:\n  - Orchard\n  - 'Demo Guest'\ntags: [one, two]\n---\nBody", "Station.md", self.vault, 9)
        self.assertEqual(row["title"], "Station")
        self.assertEqual(row["aliases"], ["Orchard", "Demo Guest"])
        self.assertEqual(row["tags"], ["one", "two"])

    def test_disabled_invalid_roots_never_traverse_or_create_cache(self):
        self.note()
        file = self.root / "not-directory"; file.write_text("synthetic")
        link = self.root / "alias"; link.symlink_to(self.vault, target_is_directory=True)
        for path in ("", str(file), str(link), str(self.root / "missing"), str(link / "sub")):
            self.configure(obsidianVault=path)
            with patch.object(obsidian, "_walk", side_effect=AssertionError("must not traverse")):
                self.assertEqual(obsidian.sync(self.data), 0)
            self.assertEqual(obsidian.cached_notes(self.data), [])
        self.assertFalse((self.data / "sources").exists())

    def test_hidden_private_large_files_and_symlinks_are_excluded(self):
        self.note()
        for folder in (".obsidian", ".git", ".trash", "node_modules", "Private", "Nested/Private", ".hidden"):
            self.note(folder + "/secret.md", "excluded")
        for marker in ("private: true", "scope: private", "visibility: private", "tags: [private]"):
            self.note("marked-" + str(len(list(self.vault.iterdir()))) + ".md", "---\n" + marker + "\n---\nExcluded")
        self.note(".hidden.md", "excluded")
        self.note("large.md", "x" * (obsidian.MAX_BYTES + 1))
        outside = self.root / "outside"; outside.mkdir(); (outside / "outside.md").write_text("excluded")
        (self.vault / "linked-folder").symlink_to(outside, target_is_directory=True)
        (self.vault / "linked.md").symlink_to(outside / "outside.md")
        (self.vault / "broken.md").symlink_to(self.root / "absent")
        before = {str(p): (p.lstat().st_mtime_ns, p.lstat().st_size) for p in self.vault.rglob("*")}
        obsidian.sync(self.data)
        self.assertEqual([r["title"] for r in obsidian.cached_notes(self.data)], ["Orchard"])
        self.assertEqual(before, {str(p): (p.lstat().st_mtime_ns, p.lstat().st_size) for p in self.vault.rglob("*")})

    def test_incremental_changes_deletion_and_file_becoming_symlink(self):
        first = self.note(); second = self.note("Station.md", "Station")
        self.assertEqual(obsidian.sync(self.data), 2)
        store = self.data / "sources/obsidian.jsonl"; before = store.stat().st_mtime_ns
        with patch.object(obsidian, "parse_note", side_effect=AssertionError("unchanged file reparsed")):
            self.assertEqual(obsidian.sync(self.data), 0)
        self.assertEqual(store.stat().st_mtime_ns, before)
        stamp = first.stat().st_mtime_ns
        first.write_text("# Updated\nChanged text"); os.utime(first, ns=(stamp, stamp))
        self.assertEqual(obsidian.sync(self.data), 1)
        self.assertIn("Updated", [r["title"] for r in obsidian.cached_notes(self.data)])
        second.unlink(); second.symlink_to(first)
        self.assertEqual(obsidian.sync(self.data), 1)
        first.unlink(); obsidian.sync(self.data)
        self.assertEqual(obsidian.cached_notes(self.data), [])

    def test_fts_links_source_sync_and_disable_gate(self):
        self.note(text="---\naliases: [Station]\n---\n# Orchard\n" + "Body. " * 60 + "[[Demo Guest]]")
        state = sources.State(self.data / "sources.json")
        self.assertEqual(sources.run(["obsidian"], state=state), {"obsidian": 1})
        index = self.index()
        self.assertEqual(index._writer.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        self.assertEqual(index.search("Station", kinds=["obsidian"])[0]["src"], "obsidian")
        found = index.find_links_files("Demo Guest")
        self.assertEqual(len(found), 1); self.assertTrue(found[0]["url"].startswith("obsidian://open?"))
        self.configure(obsidianVault="")
        self.assertEqual(index.search("Station"), [])
        self.assertEqual(index.find_links_files("Demo Guest"), [])
        self.assertEqual(sources.run(["obsidian"], state=state), {})
        index.sync(); self.assertEqual(index.stats()["src"], {})

    def test_changing_vault_hides_old_cache_without_waiting_for_sync(self):
        self.note(); index = self.index()
        other = self.root / "Second"; other.mkdir()
        self.configure(obsidianVault=str(other))
        self.assertEqual(index.search("Orchard"), [])
        self.assertEqual(obsidian.cached_notes(self.data), [])
        index.sync(); self.assertEqual(index.stats()["src"], {})

    def test_prep_surfaces_notes_without_a_person_match(self):
        self.note(); self.index()
        result = prep.about("Orchard planning", data_dir=self.data)
        self.assertEqual(result["vault_notes"][0]["title"], "Orchard")
        self.assertTrue(result["vault_notes"][0]["url"].startswith("obsidian://"))
        self.assertIn("Obsidian: Orchard", result["lines"][0])

    def test_entity_name_alias_wikilink_context_and_build(self):
        self.note("Station.md", "# Station\nReview [[Demo Guest]].")
        self.note("Other.md", "---\naliases: [Orchard]\n---\nUnrelated heading")
        obsidian.sync(self.data)
        rows = obsidian.cached_notes(self.data)
        record = {"id": "demo", "name": "Orchard", "aliases": ["Demo Guest"], "kind": "project", "pack": {}}
        enriched = entities.enrich_obsidian(record, rows)
        self.assertEqual(len(enriched["pack"]["pointers"]), 2)
        (self.data / "entities.json").write_text(json.dumps({"records": [record], "surfaces": {"orchard": [[0, "name"]]}}))
        result = entities.Store(self.data / "entities.json").context("Orchard", 3)
        self.assertIn("obsidian://", result["text"])
        self.configure(obsidianVault="")
        self.assertEqual(entities.Store(self.data / "entities.json").context("Orchard")["pointers"], [])
        self.configure()
        built = entities.build(data=self.data, vault=False, codius=self.root / "absent", ordinary=set(),
                               contacts=[{"id": "demo", "name": "Demo Guest"}], write=False)
        self.assertTrue(built["records"][0]["pack"]["pointers"][0]["value"].startswith("obsidian://"))


if __name__ == "__main__": unittest.main()
