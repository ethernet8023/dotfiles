"""Scheduler tests.

The interesting behaviour is what happens when things go wrong: repeatedly
failing a bank login is how accounts get locked, so backoff and the hard stop
matter more than the happy path. A fake clock keeps these instant.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from cctrack.web.scheduler import (
    BACKOFF_FACTOR,
    MAX_CONSECUTIVE_FAILURES,
    Scheduler,
    backoff_for,
    is_locked_vault,
)

T0 = datetime(2026, 8, 1, 9, 0, tzinfo=UTC)


class FakeClock:
    def __init__(self, now: datetime = T0):
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **kwargs) -> None:
        self.now += timedelta(**kwargs)


def make(work, *, busy=False, interval=timedelta(hours=1)):
    clock = FakeClock()
    sched = Scheduler(work, interval=interval, is_busy=lambda: busy, clock=clock)
    return sched, clock


# --- the happy path -------------------------------------------------------


def test_a_successful_tick_schedules_the_next_one():
    sched, clock = make(lambda: "3 new")
    assert sched.tick() == "ok"
    assert sched.state.last_result == "3 new"
    assert sched.state.next_run == clock.now + timedelta(hours=1)
    assert sched.state.consecutive_failures == 0


def test_success_resets_the_failure_count():
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("transient")
        return "ok"

    sched, _ = make(flaky)
    sched.tick()
    assert sched.state.consecutive_failures == 1
    sched.tick()
    assert sched.state.consecutive_failures == 0


def test_history_records_each_outcome():
    sched, _ = make(lambda: "2 new")
    sched.tick()
    assert any("ok: 2 new" in line for line in sched.state.history)


# --- not stepping on a running sync ---------------------------------------


def test_a_tick_is_skipped_while_a_sync_is_running():
    """Two logins at once fight over the browser profile and CIBC's session."""
    ran = {"n": 0}

    def work():
        ran["n"] += 1
        return "ok"

    sched, _ = make(work, busy=True)
    assert sched.tick() == "busy"
    assert ran["n"] == 0


def test_a_skipped_tick_waits_a_full_interval_rather_than_retrying():
    """The running sync covers this window; retrying immediately is pointless."""
    sched, clock = make(lambda: "ok", busy=True)
    sched.tick()
    assert sched.state.next_run == clock.now + timedelta(hours=1)


# --- backoff, the account-safety part -------------------------------------


def test_backoff_grows_with_each_consecutive_failure():
    hour = timedelta(hours=1)
    assert backoff_for(0, hour) == hour
    assert backoff_for(1, hour) == hour * BACKOFF_FACTOR
    assert backoff_for(2, hour) == hour * BACKOFF_FACTOR**2
    assert backoff_for(1, hour) < backoff_for(2, hour) < backoff_for(3, hour)


def test_a_failure_backs_off_instead_of_retrying_on_schedule():
    sched, clock = make(lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    sched.tick()
    assert sched.state.next_run > clock.now + timedelta(hours=1)


def test_repeated_failures_stop_the_scheduler():
    """A login loop against a bank is the one failure worth refusing outright."""
    sched, _ = make(lambda: (_ for _ in ()).throw(RuntimeError("bad password")))

    for _ in range(MAX_CONSECUTIVE_FAILURES - 1):
        assert sched.tick() == "failed"
    assert sched.tick() == "stopped"

    assert sched.state.stopped
    assert sched.state.next_run is None
    assert "bad password" in sched.state.paused_reason


def test_a_stopped_scheduler_does_not_run_again():
    ran = {"n": 0}

    def work():
        ran["n"] += 1
        raise RuntimeError("boom")

    sched, _ = make(work)
    for _ in range(MAX_CONSECUTIVE_FAILURES):
        sched.tick()
    before = ran["n"]

    assert sched.tick() == "stopped"
    assert ran["n"] == before, "no further attempts after stopping"


# --- a locked vault is not a failure --------------------------------------


def test_a_locked_vault_pauses_without_burning_the_budget():
    """Recoverable in one command; it must not count toward the stop limit."""
    sched, _ = make(lambda: (_ for _ in ()).throw(
        RuntimeError("BW_SESSION is unset - run: export BW_SESSION=$(bw unlock --raw)")
    ))
    assert sched.tick() == "paused"
    assert sched.state.consecutive_failures == 0
    assert "Bitwarden is locked" in sched.state.paused_reason


def test_locked_vault_detection():
    assert is_locked_vault("BW_SESSION is unset - run: export BW_SESSION=...")
    assert is_locked_vault("bitwarden is locked - run: export BW_SESSION=...")
    assert not is_locked_vault("TimeoutError: no download arrived")


# --- start and stop -------------------------------------------------------


def test_starting_clears_a_previous_stop():
    sched, _ = make(lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    for _ in range(MAX_CONSECUTIVE_FAILURES):
        sched.tick()
    assert sched.state.stopped

    sched.start()
    assert not sched.state.stopped
    assert sched.state.consecutive_failures == 0
    sched.stop()


def test_start_does_not_fire_immediately_by_default():
    """Launching the server should not trigger a bank login in the same second."""
    sched, clock = make(lambda: "ok")
    sched.start()
    assert sched.state.next_run == clock.now + timedelta(hours=1)
    sched.stop()


def test_stop_disables_it():
    sched, _ = make(lambda: "ok")
    sched.start()
    sched.stop()
    assert not sched.state.enabled
    assert sched.state.next_run is None


def test_state_serializes_for_the_api():
    sched, _ = make(lambda: "ok")
    sched.tick()
    data = sched.state.as_dict()
    assert data["interval_seconds"] == 3600
    assert data["last_result"] == "ok"
    assert isinstance(data["history"], list)
