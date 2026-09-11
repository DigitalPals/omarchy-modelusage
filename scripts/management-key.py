#!/usr/bin/env python3
"""Stage a private management key over stdin; retain it only after commit."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import sys
import uuid


def interrupted(_signum, _frame):
    raise InterruptedError


def main() -> int:
    directory_fd = None
    filename = None
    committed = False
    signal.signal(signal.SIGTERM, interrupted)
    try:
        input_stream = os.fdopen(sys.stdin.fileno(), "rb", buffering=0, closefd=False)
        request = json.loads(input_stream.readline(65537))
        key = request.pop("key").strip()
        if not key or len(key) > 8191 or any(ord(c) < 32 or ord(c) > 126 for c in key):
            raise ValueError
        config_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
        directory = config_home / "omarchy" / "model-usage" / "management-keys"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(directory_fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError
        filename = "key-" + uuid.uuid4().hex + ".key"
        fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory_fd)
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(key + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        key = ""
        print(json.dumps({"path": str(directory / filename)}), flush=True)
        # Use unbuffered stdin reads for both messages: TextIO buffering can
        # otherwise hide an already-received commit from select().
        if select.select([input_stream], [], [], 5)[0]:
            committed = input_stream.readline(32).strip() == b"commit"
        if committed:
            previous = Path(str(request.get("previousPath", ""))).expanduser()
            if previous.parent == directory and re.fullmatch(r"key-[0-9a-f]{32}\.key", previous.name):
                try:
                    info = os.stat(previous.name, dir_fd=directory_fd, follow_symlinks=False)
                    if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                        os.unlink(previous.name, dir_fd=directory_fd)
                except OSError:
                    pass
            return 0
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # Never print exception details, request contents, or the key.
        return 1
    finally:
        if directory_fd is not None:
            if filename and not committed:
                try:
                    os.unlink(filename, dir_fd=directory_fd)
                except OSError:
                    pass
            os.close(directory_fd)


if __name__ == "__main__":
    raise SystemExit(main())
