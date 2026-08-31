"""YAML-file store for local development.

Single file, whole-file read-modify-write under a process lock, written
atomically via os.replace so an interrupted write cannot leave a truncated
file behind.

Scope of the locking: ONE PROCESS. Run two uvicorn workers against the same
file and they will lose each other's writes. That is acceptable here and the
README says so -- if you need concurrency locally, run with `--workers 1`,
which is the documented default. It is also a fair small-scale illustration of
why the ECS side is a shared table rather than a shared file.
"""

from __future__ import annotations

import os
import tempfile
import threading
from pathlib import Path
from typing import Any

import yaml


class YamlStore:
    def __init__(self, path: str) -> None:
        self._path = Path(path)
        self._lock = threading.RLock()
        self._path.parent.mkdir(parents=True, exist_ok=True)

    def _read_all(self) -> dict[str, Any]:
        if not self._path.exists():
            return {}
        with self._path.open("r", encoding="utf-8") as handle:
            loaded = yaml.safe_load(handle)
        # An empty file parses to None, which is not an error.
        return loaded if isinstance(loaded, dict) else {}

    def _write_all(self, documents: dict[str, Any]) -> None:
        # Write to a temp file in the SAME directory, then rename. A rename
        # across filesystems is not atomic, so the directory must match.
        handle = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=self._path.parent,
            prefix=f".{self._path.name}.",
            suffix=".tmp",
            delete=False,
        )
        try:
            with handle:
                yaml.safe_dump(documents, handle, sort_keys=True, allow_unicode=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(handle.name, self._path)
        except BaseException:
            # Do not leave a stray temp file if the write failed.
            Path(handle.name).unlink(missing_ok=True)
            raise

    def get(self, customer_id: str) -> dict[str, Any] | None:
        with self._lock:
            return self._read_all().get(customer_id)

    def put(self, customer_id: str, document: dict[str, Any]) -> None:
        with self._lock:
            documents = self._read_all()
            documents[customer_id] = document
            self._write_all(documents)

    def describe(self) -> str:
        return "yaml"
