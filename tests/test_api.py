"""HTTP contract: endpoints, error envelope, auth, delivery safety, health."""

import threading
import time

import pytest
from fastapi.testclient import TestClient

from namao.api.app import SlidingWindowLimiter, create_app
from namao.errors import ErrorCode, NamaoError
from namao.jobs.store import JobStore
from namao.models import JobStatus
from tests.fakes import GOOD_URL, FakeEngine

BASE = "/api/v1/downloads"


@pytest.fixture(autouse=True)
def _offline_dns(monkeypatch):
    monkeypatch.setattr("namao.security.socket.getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("142.250.72.14", 0))])


@pytest.fixture()
def env(settings):
    settings.ensure_dirs()
    store = JobStore(settings)
    engine = FakeEngine(settings)
    app = create_app(settings, engine=engine, store=store)
    with TestClient(app) as client:
        yield type("Env", (), dict(settings=settings, store=store, engine=engine, client=client, app=app))


def complete_job(env, content=b"x" * 5000, title="My Video", name="media.mp4"):
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    env.store.claim_next("w1")
    jobdir = env.settings.jobs_dir / job.id
    jobdir.mkdir(parents=True)
    (jobdir / name).write_bytes(content)
    now = time.time()
    env.store.update(job.id, "w1", status=JobStatus.COMPLETED, percent=100, title=title, filename=f"{title}.mp4",
                     output_name=name, output_size=len(content), output_height=720,
                     completed_at=now, expires_at=now + 60)
    return job


def error_of(response):
    body = response.json()
    assert set(body) == {"error"}, body
    return body["error"]


# ------------------------------------------------------------------ health

def test_liveness_is_always_ok(env):
    assert env.client.get("/health/live").json()["status"] == "ok"


def test_readiness_requires_a_worker_and_healthy_dependencies(env):
    degraded = env.client.get("/health/ready")
    assert degraded.status_code == 503 and degraded.json()["checks"]["worker"]["ok"] is False
    env.store.register_worker("w1", 1)
    ready = env.client.get("/health/ready")
    assert ready.status_code == 200 and ready.json()["status"] == "ready"
    assert ready.json()["checks"]["engine"]["version"] == "2099.01.01"


def test_readiness_fails_when_the_engine_reports_missing_dependencies(env):
    env.store.register_worker("w1", 1)
    env.engine.diagnostics_problems = ("js runtime: not found",)
    response = env.client.get("/health/ready")
    assert response.status_code == 503 and response.json()["checks"]["engine"]["ok"] is False


def test_a_stale_engine_is_a_warning_not_an_outage(env):
    env.store.register_worker("w1", 1)
    env.engine.diagnostics_warnings = ("yt-dlp is 120 days old",)
    response = env.client.get("/health/ready")
    assert response.status_code == 200 and response.json()["warnings"]


def test_health_output_never_exposes_filesystem_paths(env):
    env.store.register_worker("w1", 1)
    text = env.client.get("/health/ready").text
    assert str(env.settings.data_dir) not in text and "\\\\" not in text


# ---------------------------------------------------------------- metadata

def test_metadata_returns_real_formats(env):
    response = env.client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    assert response.status_code == 200
    body = response.json()
    assert body["title"] == "Test Video" and body["platform"] == "youtube"
    assert [f["id"] for f in body["formats"]] == ["1080", "720", "audio"]
    assert body["ffmpeg"] is True


@pytest.mark.parametrize("url, status, code", [
    ("https://evil.example/?u=youtube.com", 400, "unsupported_platform"),
    ("not a url at all", 400, "invalid_url"),
    ("file:///etc/passwd", 400, "invalid_url"),
])
def test_metadata_rejects_bad_urls_with_the_error_envelope(env, url, status, code):
    response = env.client.post(f"{BASE}/metadata", json={"url": url})
    assert response.status_code == status and error_of(response)["code"] == code


def test_engine_failures_are_normalized(env):
    env.engine.metadata = NamaoError(ErrorCode.VIDEO_UNAVAILABLE, "Video unavailable")
    response = env.client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    error = error_of(response)
    assert response.status_code == 422 and error["code"] == "video_unavailable" and error["retryable"] is False


def test_unexpected_exceptions_return_a_generic_500_without_internals(env):
    env.engine.metadata = RuntimeError("Traceback: C:\\srv\\secret\\file.py token=ABC")
    # a real server answers 500; TestClient re-raises unless told not to
    with TestClient(env.app, raise_server_exceptions=False) as client:
        response = client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    assert response.status_code == 500 and error_of(response)["code"] == "internal_error"
    assert "secret" not in response.text and "Traceback" not in response.text


def test_live_streams_are_refused(env):
    import dataclasses
    env.engine.metadata = dataclasses.replace(env.engine.metadata, is_live=True)
    response = env.client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    assert error_of(response)["code"] == "unsupported_content"


def test_unknown_request_fields_are_rejected(env):
    response = env.client.post(f"{BASE}/metadata", json={"url": GOOD_URL, "extra": 1})
    assert response.status_code == 422 and error_of(response)["code"] == "invalid_request"


# ------------------------------------------------------------------- create

def test_create_returns_202_with_location_and_a_queued_job(env):
    response = env.client.post(BASE, json={"url": GOOD_URL, "quality": "720"})
    body = response.json()
    assert response.status_code == 202 and body["status"] == "queued" and body["quality"] == "720"
    assert response.headers["location"] == f"{BASE}/{body['id']}"
    assert body["progress"]["percent"] == 0 and body["result"] is None and body["error"] is None


@pytest.mark.parametrize("quality", ["", "0", "1080p", "best;ls", "99999", "-1"])
def test_create_rejects_invalid_quality(env, quality):
    response = env.client.post(BASE, json={"url": GOOD_URL, "quality": quality})
    assert response.status_code in (400, 422)
    assert error_of(response)["code"] in ("invalid_quality", "invalid_request")


def test_create_rejects_ssrf_style_urls(env):
    response = env.client.post(BASE, json={"url": "http://169.254.169.254/latest/meta-data"})
    assert response.status_code == 400 and env.store.open_job_count() == 0


def test_idempotency_key_prevents_duplicate_jobs(env):
    headers = {"Idempotency-Key": "abc-12345678"}
    first = env.client.post(BASE, json={"url": GOOD_URL}, headers=headers)
    second = env.client.post(BASE, json={"url": GOOD_URL}, headers=headers)
    assert first.status_code == 202 and second.status_code == 200
    assert first.json()["id"] == second.json()["id"] and env.store.open_job_count() == 1


def test_bad_idempotency_key_is_rejected(env):
    response = env.client.post(BASE, json={"url": GOOD_URL}, headers={"Idempotency-Key": "short"})
    assert response.status_code == 422


def test_queue_limit_returns_503(env):
    small = env.settings.with_overrides(max_queue_length=1)
    with TestClient(create_app(small, engine=env.engine, store=env.store)) as client:
        assert client.post(BASE, json={"url": GOOD_URL}).status_code == 202
        blocked = client.post(BASE, json={"url": GOOD_URL})
    assert blocked.status_code == 503 and error_of(blocked)["code"] == "queue_full"


def test_rate_limit_returns_429_with_the_error_envelope(env):
    limited = env.settings.with_overrides(rate_limit_per_minute=2)
    with TestClient(create_app(limited, engine=env.engine, store=env.store)) as client:
        codes = [client.post(f"{BASE}/metadata", json={"url": GOOD_URL}).status_code for _ in range(4)]
        last = client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    assert codes[:2] == [200, 200] and codes[2:] == [429, 429]
    assert error_of(last)["code"] == "too_many_requests"


def test_sliding_window_limiter_forgets_old_hits():
    limiter = SlidingWindowLimiter(2, window_seconds=0.1)
    assert limiter.allow("a") and limiter.allow("a") and not limiter.allow("a")
    assert limiter.allow("b")
    time.sleep(0.15)
    assert limiter.allow("a")


# --------------------------------------------------------------------- read

def test_get_job_and_unknown_ids(env):
    job = env.client.post(BASE, json={"url": GOOD_URL}).json()
    assert env.client.get(f"{BASE}/{job['id']}").json()["id"] == job["id"]
    for bad in ("0" * 24, "short", "../../etc/passwd", "a" * 100):
        response = env.client.get(f"{BASE}/{bad}")
        assert response.status_code == 404 and error_of(response)["code"] == "not_found"


def test_there_is_no_endpoint_to_list_other_users_jobs(env):
    for method in ("get", "delete"):
        assert getattr(env.client, method)(BASE).status_code in (404, 405)


def test_completed_job_exposes_a_result_but_no_internal_paths(env):
    job = complete_job(env)
    body = env.client.get(f"{BASE}/{job.id}").json()
    assert body["status"] == "completed" and body["result"]["download_url"] == f"{BASE}/{job.id}/file"
    assert body["result"]["size_bytes"] == 5000 and body["result"]["height"] == 720
    assert str(env.settings.data_dir) not in str(body) and "media.mp4" not in str(body)


def test_failed_job_exposes_the_normalized_error(env):
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    env.store.claim_next("w1")
    env.store.update(job.id, "w1", status=JobStatus.FAILED, error_code="geo_restricted", error_message="Nope",
                     error_retryable=False, error_detail="x")
    body = env.client.get(f"{BASE}/{job.id}").json()
    assert body["status"] == "failed" and body["error"]["code"] == "geo_restricted" and body["result"] is None


# ------------------------------------------------------------------- cancel

def test_cancel_queued_job(env):
    job = env.client.post(BASE, json={"url": GOOD_URL}).json()
    response = env.client.post(f"{BASE}/{job['id']}/cancel")
    assert response.status_code == 200 and response.json()["status"] == "cancelled"
    assert env.client.post(f"{BASE}/{job['id']}/cancel").json()["status"] == "cancelled"  # idempotent


def test_cancel_running_job_sets_the_flag(env):
    job = env.client.post(BASE, json={"url": GOOD_URL}).json()
    env.store.claim_next("w1")
    assert env.client.post(f"{BASE}/{job['id']}/cancel").status_code == 200
    assert env.store.is_cancel_requested(job["id"])


def test_cancel_completed_job_conflicts_and_unknown_is_404(env):
    job = complete_job(env)
    response = env.client.post(f"{BASE}/{job.id}/cancel")
    assert response.status_code == 409 and error_of(response)["code"] == "conflict"
    assert env.client.post(f"{BASE}/{'z' * 24}/cancel").status_code == 404


# --------------------------------------------------------------------- file

def test_file_download_is_an_attachment_with_safe_headers(env):
    job = complete_job(env, content=b"0123456789" * 500, title='Evil "name"/..\\x')
    response = env.client.get(f"{BASE}/{job.id}/file")
    assert response.status_code == 200 and response.content == b"0123456789" * 500
    assert response.headers["content-disposition"].startswith("attachment")
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["content-type"].startswith("video/mp4")
    assert response.headers["cache-control"] == "private, no-store"


def test_file_supports_range_requests(env):
    job = complete_job(env, content=bytes(range(256)) * 20)
    response = env.client.get(f"{BASE}/{job.id}/file", headers={"Range": "bytes=10-19"})
    assert response.status_code == 206 and response.content == bytes(range(10, 20))


def test_file_is_unavailable_until_the_job_completes(env):
    job = env.client.post(BASE, json={"url": GOOD_URL}).json()
    response = env.client.get(f"{BASE}/{job['id']}/file")
    assert response.status_code == 409 and error_of(response)["code"] == "conflict"


def test_expired_files_return_410(env):
    job = complete_job(env)
    env.store.mark_files_deleted(job.id)
    response = env.client.get(f"{BASE}/{job.id}/file")
    assert response.status_code == 410 and error_of(response)["code"] == "expired"


def test_file_past_expiry_is_refused_even_before_cleanup_runs(env):
    job = complete_job(env)
    import sqlite3
    with sqlite3.connect(env.settings.db_path) as conn:
        conn.execute("UPDATE jobs SET expires_at = ? WHERE id = ?", (time.time() - 5, job.id))
    assert env.client.get(f"{BASE}/{job.id}/file").status_code == 410


def test_a_tampered_output_path_cannot_read_arbitrary_files(env, tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("top secret")
    job = complete_job(env)
    import sqlite3
    with sqlite3.connect(env.settings.db_path) as conn:
        conn.execute("UPDATE jobs SET output_name = ? WHERE id = ?", (f"../../../{secret.name}", job.id))
        conn.execute("UPDATE jobs SET output_name = ? WHERE id = ?", (str(secret), job.id))
    response = env.client.get(f"{BASE}/{job.id}/file")
    assert response.status_code == 410 and "top secret" not in response.text


# --------------------------------------------------------------------- auth

def test_api_key_protects_the_job_api_but_not_health(env):
    secured = env.settings.with_overrides(api_key="s3cret-key")
    with TestClient(create_app(secured, engine=env.engine, store=env.store)) as client:
        assert client.get("/health/live").status_code == 200
        assert client.post(BASE, json={"url": GOOD_URL}).status_code == 401
        assert client.post(BASE, json={"url": GOOD_URL}, headers={"Authorization": "Bearer wrong"}).status_code == 401
        ok = client.post(BASE, json={"url": GOOD_URL}, headers={"Authorization": "Bearer s3cret-key"})
        assert ok.status_code == 202
        assert client.post(BASE, json={"url": GOOD_URL}, headers={"X-API-Key": "s3cret-key"}).status_code == 202
        job_id = ok.json()["id"]
        assert client.get(f"{BASE}/{job_id}").status_code == 401
        assert error_of(client.get(f"{BASE}/{job_id}"))["code"] == "unauthorized"


# ---------------------------------------------------------------------- SSE

def test_progress_stream_emits_state_changes_until_terminal(env):
    job = env.client.post(BASE, json={"url": GOOD_URL}).json()
    claimed = env.store.claim_next("w1")

    def finish():
        time.sleep(0.4)
        env.store.update(claimed.id, "w1", status=JobStatus.DOWNLOADING, percent=40)
        time.sleep(1.2)
        env.store.update(claimed.id, "w1", status=JobStatus.FAILED, error_code="video_unavailable",
                         error_message="gone", error_retryable=False)

    threading.Thread(target=finish, daemon=True).start()
    import json
    statuses = []
    with env.client.stream("GET", f"{BASE}/{job['id']}/progress") as response:
        assert response.headers["content-type"].startswith("text/event-stream")
        for line in response.iter_lines():
            if line.startswith("data: "):
                statuses.append(json.loads(line[6:])["status"])
    assert statuses[0] == "validating" and "downloading" in statuses and statuses[-1] == "failed"


def test_progress_stream_for_unknown_job_is_404(env):
    assert env.client.get(f"{BASE}/{'q' * 24}/progress").status_code == 404


# ------------------------------------------------------------------- schema

def test_security_headers_are_present(env):
    response = env.client.get("/health/live")
    assert response.headers["x-content-type-options"] == "nosniff" and response.headers["x-frame-options"] == "DENY"


def test_openapi_documents_every_public_route(env):
    paths = env.client.get("/openapi.json").json()["paths"]
    expected = {
        f"{BASE}/metadata": {"post"}, BASE: {"post"}, f"{BASE}/{{job_id}}": {"get"},
        f"{BASE}/{{job_id}}/progress": {"get"}, f"{BASE}/{{job_id}}/cancel": {"post"},
        f"{BASE}/{{job_id}}/file": {"get"}, "/health/live": {"get"}, "/health/ready": {"get"},
    }
    for path, methods in expected.items():
        assert methods <= set(paths[path]), path
