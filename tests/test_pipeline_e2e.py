"""End to end: HTTP API -> SQLite queue -> embedded worker -> real yt-dlp/FFmpeg -> file.

Uses the real engine against the local synthetic DASH server. This is the same
code path the Docker deployment runs (the worker is just in-process here).
"""

import subprocess

import pytest
from fastapi.testclient import TestClient

from namao.api.app import create_app
from tests.conftest import requires_ffmpeg, wait_for

pytestmark = [pytest.mark.integration, requires_ffmpeg]

BASE = "/api/v1/downloads"
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}


@pytest.fixture()
def client(settings):
    app = create_app(settings.with_overrides(embedded_worker=True, retention_seconds=3))
    with TestClient(app) as c:
        wait_for(lambda: c.get("/health/ready").status_code == 200, timeout=20)
        yield c


def submit(client, url, quality="best"):
    response = client.post(BASE, json={"url": url, "quality": quality})
    assert response.status_code == 202, response.text
    return response.json()["id"]


def wait_terminal(client, job_id, timeout=90):
    return wait_for(
        lambda: (lambda body: body if body["status"] in TERMINAL else None)(client.get(f"{BASE}/{job_id}").json()),
        timeout=timeout,
    )


def test_ready_endpoint_reports_the_real_dependency_chain(client):
    body = client.get("/health/ready").json()
    assert body["status"] == "ready"
    for name in ("engine", "ffmpeg", "ffprobe", "yt-dlp-ejs", "database", "storage", "worker"):
        assert body["checks"][name]["ok"], name


def test_download_flows_from_request_to_a_playable_file(client, media_server, settings):
    job_id = submit(client, media_server(), "best")
    job = wait_terminal(client, job_id)
    assert job["status"] == "completed", job
    assert job["progress"]["percent"] == 100 and job["result"]["height"] == 360

    response = client.get(job["result"]["download_url"])
    assert response.status_code == 200 and len(response.content) == job["result"]["size_bytes"]
    media = settings.data_dir / "delivered.mp4"
    media.write_bytes(response.content)
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(media)],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    assert sorted(probe) == ["audio", "video"], "delivered file has both streams (merge happened)"


def test_audio_download_flow(client, media_server):
    job = wait_terminal(client, submit(client, media_server(), "audio"))
    assert job["status"] == "completed" and job["result"]["filename"].endswith(".mp3")
    assert job["result"]["height"] is None


def test_unavailable_resolution_fails_cleanly_and_is_never_reported_as_success(client, media_server, settings):
    job_id = submit(client, media_server(), "1080")
    job = wait_terminal(client, job_id)
    assert job["status"] == "failed" and job["error"]["code"] == "format_unavailable"
    assert job["result"] is None and client.get(f"{BASE}/{job_id}/file").status_code == 409
    wait_for(lambda: not (settings.jobs_dir / job_id).exists(), timeout=5)


def test_missing_source_fails_with_a_classified_error(client, media_server):
    job = wait_terminal(client, submit(client, media_server("gone/manifest.mpd")))
    assert job["status"] == "failed" and job["error"]["code"] in ("video_unavailable", "download_failed")
    assert job["error"]["retryable"] is False or job["error"]["code"] == "download_failed"


def test_cancel_a_running_job_stops_it_and_removes_partial_files(client, media_server, settings):
    job_id = submit(client, media_server("slow/manifest.mpd"))
    wait_for(lambda: client.get(f"{BASE}/{job_id}").json()["status"] in ("downloading", "fetching_metadata"), timeout=30)
    assert client.post(f"{BASE}/{job_id}/cancel").status_code == 200
    job = wait_terminal(client, job_id, timeout=30)
    assert job["status"] == "cancelled" and job["result"] is None
    jobdir = settings.jobs_dir / job_id
    try:
        wait_for(lambda: not jobdir.exists(), timeout=10)
    except AssertionError:
        raise AssertionError(f"cancelled job directory not removed; left: {[str(p.relative_to(jobdir)) for p in jobdir.rglob('*')]}")


def test_finished_files_expire_and_are_deleted(client, media_server, settings):
    job_id = submit(client, media_server(), "180")
    wait_terminal(client, job_id)
    assert (settings.jobs_dir / job_id).exists()
    wait_for(lambda: not (settings.jobs_dir / job_id).exists(), timeout=20)
    gone = client.get(f"{BASE}/{job_id}/file")
    assert gone.status_code == 410 and gone.json()["error"]["code"] == "expired"


def test_concurrent_jobs_are_isolated_and_all_complete(client, media_server):
    ids = [submit(client, media_server(), q) for q in ("180", "360", "best")]
    jobs = [wait_terminal(client, i) for i in ids]
    assert [j["status"] for j in jobs] == ["completed"] * 3
    assert [j["result"]["height"] for j in jobs] == [180, 360, 360]
    assert len({j["id"] for j in jobs}) == 3
    assert len({j["result"]["size_bytes"] for j in jobs}) >= 2, "different qualities produce different files"
