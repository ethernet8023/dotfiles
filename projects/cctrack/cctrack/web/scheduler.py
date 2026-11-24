"""Periodic background sync while the server is running.

Off by default. When enabled it runs the same sync the button does, on an
interval, through the same JobRunner -- so a scheduled run and a manual one
can never overlap.

Three things this has to get right, because getting them wrong is expensive:

  - **Backoff.** Repeatedly failing a bank login is how accounts get locked.
    Consecutive failures back off exponentially and then stop entirely rather
    than retrying forever at the base interval.
  - **A locked vault is not a failure.** Bitwarden locks and the sync cannot
    proceed; that is a paused state to report once, not an hourly alarm.
  - **Never queue.** If a sync is already running -- manual or scheduled --
    the tick is skipped, not deferred. Two logins at once fight over the
    browser profile and CIBC's session.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

DEFAULT_INTERVAL = timedelta(hours=1)

MAX_CONSECUTIVE_FAILURES = 4
"""Give up after this many failures in a row.

Not a retry budget for one attempt -- a stop switch. Whatever is wrong (bad
password, CIBC outage, changed markup) will not fix itself by trying again in
an hour, and a login loop against a bank is the one failure mode worth
refusing outright.
"""

BACKOFF_FACTOR = 3
"""Each consecutive failure multiplies the wait: 1h, 3h, 9h, 27h, stop."""


@dataclass
class SchedulerState:
    enabled: bool = False
    interval: timedelta = DEFAULT_INTERVAL
    last_run: datetime | None = None
    last_result: str | None = None
    next_run: datetime | None = None
    consecutive_failures: int = 0
    paused_reason: str | None = None
    history: list[str] = field(default_factory=list)

    @property
    def stopped(self) -> bool:
        return self.paused_reason is not None

    def as_dict(self) -> dict:
        return {
            "enabled": self.enabled,
            "interval_seconds": int(self.interval.total_seconds()),
            "last_run": self.last_run.isoformat() if self.last_run else None,
            "last_result": self.last_result,
            "next_run": self.next_run.isoformat() if self.next_run else None,
            "consecutive_failures": self.consecutive_failures,
            "paused_reason": self.paused_reason,
            "history": self.history[-10:],
        }


def backoff_for(failures: int, interval: timedelta) -> timedelta:
    """How long to wait after `failures` consecutive failures."""
    if failures <= 0:
        return interval
    return interval * (BACKOFF_FACTOR ** min(failures, MAX_CONSECUTIVE_FAILURES))


def is_locked_vault(error: str) -> bool:
    """Does this error mean 'unlock Bitwarden', rather than 'something broke'?

    A locked vault is an expected, recoverable state. Treating it as a failure
    would burn the backoff budget and eventually stop the scheduler over
    something the user fixes with one command.
    """
    lowered = error.lower()
    return "bw_session" in lowered or "bitwarden is locked" in lowered


class Scheduler:
    """Runs `work` every `interval` in a daemon thread."""

    def __init__(
        self,
        work: Callable[[], str],
        *,
        interval: timedelta = DEFAULT_INTERVAL,
        is_busy: Callable[[], bool] | None = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.state = SchedulerState(interval=interval)
        self._work = work
        self._is_busy = is_busy or (lambda: False)
        self._clock = clock or (lambda: datetime.now(UTC))
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._stop = False

    # -- lifecycle ---------------------------------------------------------

    def start(self, *, run_immediately: bool = False) -> None:
        if self._thread and self._thread.is_alive():
            return
        self.state.enabled = True
        self.state.paused_reason = None
        self.state.consecutive_failures = 0
        self._stop = False
        now = self._clock()
        self.state.next_run = now if run_immediately else now + self.state.interval

        self._thread = threading.Thread(
            target=self._loop, name="cctrack-scheduler", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop = True
        self.state.enabled = False
        self.state.next_run = None
        self._wake.set()

    def _loop(self) -> None:
        while not self._stop:
            wait = self._seconds_until_next()
            if self._wake.wait(timeout=wait):
                self._wake.clear()
                if self._stop:
                    return
            if self._stop or self.state.stopped:
                return
            if self._clock() >= (self.state.next_run or self._clock()):
                self.tick()

    def _seconds_until_next(self) -> float:
        if self.state.next_run is None:
            return 60.0
        remaining = (self.state.next_run - self._clock()).total_seconds()
        # Cap the sleep so stop() and clock changes are noticed promptly.
        return max(0.0, min(remaining, 60.0))

    # -- one iteration -----------------------------------------------------

    def tick(self) -> str:
        """Run once. Returns a short outcome string. Safe to call directly."""
        now = self._clock()

        if self.state.stopped:
            return "stopped"

        if self._is_busy():
            # Skipped, not deferred: the running sync covers this window.
            self.state.next_run = now + self.state.interval
            self._note(now, "skipped: a sync was already running")
            return "busy"

        self.state.last_run = now
        try:
            result = self._work()
        except Exception as exc:  # noqa: BLE001 - reported, never raised into the thread
            return self._record_failure(now, f"{type(exc).__name__}: {exc}")

        self.state.consecutive_failures = 0
        self.state.last_result = result
        self.state.next_run = now + self.state.interval
        self._note(now, f"ok: {result}")
        return "ok"

    def _record_failure(self, now: datetime, error: str) -> str:
        if is_locked_vault(error):
            # Recoverable by the user in one command; do not spend the budget.
            self.state.paused_reason = (
                "Bitwarden is locked. Unlock it and re-enable the schedule."
            )
            self.state.last_result = error
            self.state.next_run = None
            self._note(now, "paused: vault locked")
            return "paused"

        self.state.consecutive_failures += 1
        self.state.last_result = error

        if self.state.consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
            self.state.paused_reason = (
                f"{self.state.consecutive_failures} syncs failed in a row. "
                f"Stopped rather than keep retrying a bank login. Last error: {error}"
            )
            self.state.next_run = None
            self._note(now, f"stopped after {self.state.consecutive_failures} failures")
            return "stopped"

        wait = backoff_for(self.state.consecutive_failures, self.state.interval)
        self.state.next_run = now + wait
        self._note(now, f"failed ({self.state.consecutive_failures}), "
                        f"next try in {wait}")
        return "failed"

    def _note(self, when: datetime, message: str) -> None:
        self.state.history.append(f"{when:%Y-%m-%d %H:%M}  {message}")
        del self.state.history[:-50]
