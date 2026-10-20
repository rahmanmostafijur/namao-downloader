"""Expiry sweep, orphan removal and tolerant deletion."""

import os
import time

import pytest

from namao.jobs import cleanup
from namao.jobs.cleanup import dir_size, remove_tree, sweep
from namao.jobs.store import JobStore
from namao.models import JobStatus


@pytest.fixture()
def store(settings):
    settings.ensure_dirs()
    return JobStore(settings)


def finished_job(store, settings, *, expires_in, with_files=True):
    job, _ = store.create_job(url="https://youtu.be/abc", platform="youtube", quality="best", max_attempts=1)
    store.claim_next("w1")
    now = time.time()
    store.update(job.id, "w1", status=JobStatus.COMPLETED, completed_at=now, expires_at=now + expires_in,
                 output_name="media.mp4")
    if with_files:
        jobdir = settings.jobs_dir / job.id
        jobdir.mkdir(parents=True)
        (jobdir / "media.mp4").write_bytes(b"x" * 100)
    return job


def test_expired_job_files_are_deleted_and_recorded(store, settings):
    job = finished_job(store, settings, expires_in=-1)
    assert sweep(settings, store)["expired"] == 1
    assert not (settings.jobs_dir / job.id).exists()
    assert store.get(job.id).files_deleted is True


def test_unexpired_job_files_are_kept(store, settings):
    job = finished_job(store, settings, expires_in=600)
    assert sweep(settings, store)["expired"] == 0
    assert (settings.jobs_dir / job.id / "media.mp4").is_file()


def test_failed_deletion_is_not_recorded_as_success_so_it_is_retried(store, settings, monkeypatch):
    job = finished_job(store, settings, expires_in=-1)
    monkeypatch.setattr(cleanup, "remove_tree", lambda path: False)
    assert sweep(settings, store)["expired"] == 0
    assert store.get(job.id).files_deleted is False
    monkeypatch.undo()
    assert sweep(settings, store)["expired"] == 1


def test_old_unknown_directories_are_removed_but_fresh_ones_are_not(store, settings):
    old = settings.jobs_dir / "orphan-old"
    fresh = settings.jobs_dir / "orphan-fresh"
    for d in (old, fresh):
        d.mkdir(parents=True)
        (d / "f").write_bytes(b"x")
    long_ago = time.time() - 2 * cleanup.ORPHAN_MIN_AGE_SECONDS
    os.utime(old, (long_ago, long_ago))
    assert sweep(settings, store)["orphans"] == 1
    assert not old.exists() and fresh.exists()


def test_a_directory_belonging_to_a_live_job_is_never_treated_as_an_orphan(store, settings):
    job, _ = store.create_job(url="https://youtu.be/abc", platform="youtube", quality="best", max_attempts=1)
    store.claim_next("w1")
    jobdir = settings.jobs_dir / job.id
    jobdir.mkdir(parents=True)
    long_ago = time.time() - 2 * cleanup.ORPHAN_MIN_AGE_SECONDS
    os.utime(jobdir, (long_ago, long_ago))
    sweep(settings, store)
    assert jobdir.exists()


def test_deletion_refuses_paths_outside_the_jobs_directory(settings):
    settings.ensure_dirs()
    outside = settings.data_dir / "precious"
    outside.mkdir()
    cleanup.remove_job_files(settings, ["../precious", "..", "."])
    assert outside.exists() and settings.jobs_dir.exists()


def test_remove_tree_waits_out_a_briefly_locked_file(tmp_path, monkeypatch):
    target = tmp_path / "job"
    target.mkdir()
    (target / "f.part").write_bytes(b"x")
    real_rmtree = cleanup.shutil.rmtree
    calls = {"n": 0}

    def flaky(path, ignore_errors=False):
        calls["n"] += 1
        if calls["n"] < 3:  # first two attempts fail silently, like a locked file on Windows
            return
        real_rmtree(path, ignore_errors=ignore_errors)

    monkeypatch.setattr(cleanup.shutil, "rmtree", flaky)
    monkeypatch.setattr(cleanup, "_REMOVE_DELAY_SECONDS", 0.01)
    assert remove_tree(target) is True and calls["n"] == 3


def test_remove_tree_reports_failure_honestly(tmp_path, monkeypatch):
    target = tmp_path / "job"
    target.mkdir()
    monkeypatch.setattr(cleanup.shutil, "rmtree", lambda *a, **k: None)
    monkeypatch.setattr(cleanup, "_REMOVE_DELAY_SECONDS", 0.001)
    assert remove_tree(target) is False


def test_dir_size_counts_nested_files(tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "x").write_bytes(b"1" * 10)
    (tmp_path / "y").write_bytes(b"1" * 5)
    assert dir_size(tmp_path) == 15 and dir_size(tmp_path / "missing") == 0
