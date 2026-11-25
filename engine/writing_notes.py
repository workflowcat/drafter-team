"""Writing-note normalization shared by local and Claude prompts. No prompt labels or I/O."""


def normalize(notes, limit=300):
    """Collapse whitespace, then keep the first characters, including a space at the cut."""
    return " ".join((notes or "").split())[:limit]
