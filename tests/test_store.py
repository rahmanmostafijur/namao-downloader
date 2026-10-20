"""Durable job store: claiming, ownership, cancellation, reaping, expiry."""

import threading
import time

import pytest

from namao.jobs.store import JobStore
from namao.models import JobStatus


@pytest.fixture()
def store(settings):
    settings.ensure_dirs()
    return JobStore(settings)


def make(store, **kwargs):
    defaults = dict(url="https://youtu.be/abc", platform="youtube", quality="best", max_attempts=3)
    defaults.update(kwargs)
    return store.create_job(**defaults)


def test_create_and_get(store):
    job, created = make(store)
    assert created and job.status == JobStatus.QUEUED and job.attempt == 0
    assert store.get(job.id) == job
    assert store.get("missing") is None


def test_job_ids_are_unguessable_and_unique(store):
    ids = {make(store)[0].id for _ in range(50)}
    assert len(ids) == 50 and all(len(i) >= 24 for i in ids)


def test_idempotency_key_returns_the_original_job(store):
    first, created_first = make(store, idempotency_key="key-12345678")
    second, created_second = make(store, idempotency_key="key-12345678")
    assert created_first and not created_second and first.id == second.id


def test_claim_is_fifo_and_increments_attempt(store):
    a, _ = make(store)
    time.sleep(0.01)
    b, _ = make(store)
    claimed = store.claim_next("w1")
    assert claimed.id == a.id and claimed.status == JobStatus.VALIDATING and claimed.attempt == 1
    assert store.claim_next("w1").id == b.id
    assert store.claim_next("w1") is None


def test_a_job_is_claimed_by_exactly_one_of_many_racing_workers(store):
    make(store)
    winners = []
    barrier = threading.Barrier(8)

    def race(n):
        barrier.wait()
        job = store.claim_next(f"w{n}")
        if job:
            winners.append(n)

    threads = [threading.Thread(target=race, args=(n,)) for n in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(winners) == 1


def test_scheduled_retry_is_not_claimable_until_due(store):
    job, _ = make(store)
    claimed = store.claim_next("w1")
    assert store.schedule_retry(job.id, "w1", next_attempt_at=time.time() + 60, error_code="network_transient",
                                error_message="m", error_retryable=True, error_detail=None)
    assert store.get(job.id).status == JobStatus.QUEUED
    assert store.claim_next("w2") is None
    assert claimed.attempt == 1
    assert store.get(job.id).worker_id is None  # ownership released for the retry


def test_updates_are_compare_and_set_on_the_owner(store):
    job, _ = make(store)
    store.claim_next("w1")
    assert store.update(job.id, "w1", percent=10)
    assert not store.update(job.id, "someone-else", percent=50)
    assert store.get(job.id).percent == 10


def test_terminal_jobs_cannot_be_overwritten_by_a_zombie_worker(store):
    job, _ = make(store)
    store.claim_next("w1")
    assert store.update(job.id, "w1", status=JobStatus.FAILED, error_code="x")
    assert not store.update(job.id, "w1", status=JobStatus.COMPLETED)
    assert store.get(job.id).status == JobStatus.FAILED


def test_unknown_columns_are_refused(store):
    job, _ = make(store)
    store.claim_next("w1")
    with pytest.raises(ValueError):
        store.update(job.id, "w1", url="https://evil.example")


def test_cancelling_a_queued_job_is_immediate(store):
    job, _ = make(store)
    cancelled = store.request_cancel(job.id, 60)
    assert cancelled.status == JobStatus.CANCELLED and cancelled.error_code == "cancelled"
    assert store.claim_next("w1") is None


def test_cancelling_a_running_job_flags_it_for_its_worker(store):
    job, _ = make(store)
    store.claim_next("w1")
    flagged = store.request_cancel(job.id, 60)
    assert flagged.status == JobStatus.VALIDATING and flagged.cancel_requested
    assert store.is_cancel_requested(job.id)


def test_cancelling_unknown_or_finished_jobs_is_safe(store):
    assert store.request_cancel("nope", 60) is None
    job, _ = make(store)
    store.claim_next("w1")
    store.update(job.id, "w1", status=JobStatus.COMPLETED)
    assert store.request_cancel(job.id, 60).status == JobStatus.COMPLETED


def test_stale_running_jobs_become_interrupted(store):
    job, _ = make(store)
    store.claim_next("dead-worker")
    time.sleep(0.05)
    assert store.reap_stale(stale_after=0.01, retention_seconds=60) == [job.id]
    reaped = store.get(job.id)
    assert reaped.status == JobStatus.INTERRUPTED and reaped.error_retryable is True
    assert store.reap_stale(stale_after=0.01, retention_seconds=60) == []


def test_fresh_heartbeats_prevent_reaping(store):
    job, _ = make(store)
    store.claim_next("w1")
    store.heartbeat_jobs("w1", [job.id])
    assert store.reap_stale(stale_after=5, retention_seconds=60) == []


def test_graceful_shutdown_marks_only_that_workers_jobs_interrupted(store):
    mine, _ = make(store)
    store.claim_next("w1")
    other, _ = make(store)
    store.claim_next("w2")
    assert store.interrupt_worker_jobs("w1", 60) == [mine.id]
    assert store.get(other.id).status == JobStatus.VALIDATING


def test_worker_liveness(store):
    assert store.alive_worker_count(stale_after=5) == 0
    store.register_worker("w1", 2)
    assert store.alive_worker_count(stale_after=5) == 1
    store.unregister_worker("w1")
    assert store.alive_worker_count(stale_after=5) == 0


def test_expired_jobs_are_listed_once_and_old_rows_are_purged(store):
    job, _ = make(store)
    store.claim_next("w1")
    now = time.time()
    store.update(job.id, "w1", status=JobStatus.COMPLETED, completed_at=now - 100, expires_at=now - 1)
    assert [j.id for j in store.expired_with_files()] == [job.id]
    store.mark_files_deleted(job.id)
    assert store.expired_with_files() == []
    assert store.purge_rows_older_than(10) == 1
    assert store.get(job.id) is None


def test_open_job_count_ignores_terminal_jobs(store):
    a, _ = make(store)
    make(store)
    assert store.open_job_count() == 2
    store.request_cancel(a.id, 60)
    assert store.open_job_count() == 1


def test_a_retry_scheduled_after_a_cancel_request_ends_cancelled_not_stuck_in_queue(store):
    job, _ = make(store)
    store.claim_next("w1")
    store.request_cancel(job.id, retention_seconds=60)  # user cancels while the attempt is running
    assert store.schedule_retry(job.id, "w1", next_attempt_at=time.time(), error_code="network_transient",
                                error_message="m", error_retryable=True, error_detail=None)
    final = store.get(job.id)
    assert final.status == JobStatus.CANCELLED and final.expires_at is not None
    assert store.open_job_count() == 0 and store.claim_next("w2") is None
