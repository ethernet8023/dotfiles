"""Background jobs for work too slow to hold an HTTP request open.

A sync logs into CIBC, may wait two minutes for an SMS code, then downloads a
file per month. That cannot happen inside a request, so the button starts a
job and the page polls its progress.

One job at a time, on purpose: two concurrent syncs would fight over the
browser profile and CIBC's session, and a second login attempt mid-2FA is how
accounts get locked.
"""

from __future__ import annotations

import threading
import traceback
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Literal

Status = Literal["running", "done", "failed"]


@dataclass
class Job:
    name: str
    status: Status = "running"
    lines: list[str] = field(default_factory=list)
    started_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())
    finished_at: str | None = None
    result: str | None = None
    error: str | None = None

    def log(self, message: str) -> None:
        self.lines.append(f"{datetime.now(UTC):%H:%M:%S}  {message}")

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "result": self.result,
            "error": self.error,
            "lines": self.lines,
        }


class JobRunner:
    """Runs one named job at a time and keeps its log for polling."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._current: Job | None = None
        self._last: Job | None = None
        self._thread: threading.Thread | None = None

    @property
    def current(self) -> Job | None:
        with self._lock:
            return self._current

    @property
    def last(self) -> Job | None:
        with self._lock:
            return self._current or self._last

    def is_running(self) -> bool:
        with self._lock:
            return self._current is not None

    def start(self, name: str, work: Callable[[Job], str]) -> Job:
        """Start `work` in a thread. Raises RuntimeError if one is already going.

        `work` receives the Job so it can log progress, and returns a summary
        string shown when it finishes.
        """
        with self._lock:
            if self._current is not None:
                raise RuntimeError(f"{self._current.name} is already running")
            job = Job(name=name)
            self._current = job

        def run() -> None:
            try:
                job.result = work(job)
                job.status = "done"
            except Exception as exc:  # noqa: BLE001 - surfaced to the user
                job.status = "failed"
                job.error = f"{type(exc).__name__}: {exc}"
                job.log(f"failed: {job.error}")
                # Full trace to the server log; the page shows the short form.
                traceback.print_exc()
            finally:
                job.finished_at = datetime.now(UTC).isoformat()
                with self._lock:
                    self._last = job
                    self._current = None

        thread = threading.Thread(target=run, name=f"cctrack-{name}", daemon=True)
        self._thread = thread
        thread.start()
        return job

    def join(self, timeout: float | None = None) -> None:
        """Wait for the running job. Used by tests and the CLI."""
        if self._thread is not None:
            self._thread.join(timeout)


runner = JobRunner()
