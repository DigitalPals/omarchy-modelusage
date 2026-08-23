"""Shared state-file and error-sanitizing helpers for Model Usage backends."""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


def clean_message(value: Any) -> str:
    """Return a short display-safe message with common credential forms removed."""
    text = str(value or "").replace("\n", " ").replace("\r", " ").strip()
    text = re.sub(r"(?i)bearer\s+[a-z0-9._~+/=-]+", "Bearer [redacted]", text)
    key = r"(?:access[_ -]?token|refresh[_ -]?token|api[_ -]?key|authorization)"
    text = re.sub(
        rf"(?i)([\"']?{key}[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)",
        r"\1[redacted]",
        text,
    )
    return text[:300]


def atomic_write_json(path: Path, payload: Any) -> None:
    """Atomically write private JSON state below a user-only directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise
