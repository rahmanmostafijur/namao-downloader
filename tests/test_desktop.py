"""Desktop mode: local-only guards, output-folder preference, save-to-folder."""

import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from namao import desktop
from namao.api.app import create_app
from namao.errors import NamaoError
from namao.jobs.store import JobStore
from namao.models import JobStatus
from tests.fakes import GOOD_URL, FakeEngine

HDR = {"X-Namao-Desktop": "1"}
BASE = "/api/v1/desktop"


@pytest.fixture()
def home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setattr(Path, "home", staticmethod(lambda: home))
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    return home


@pytest.fixture()
def env(settings, home, monkeypatch):
    monkeypatch.setattr("namao.security.socket.getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("142.250.72.14", 0))])
    settings = settings.with_overrides(desktop_mode=True)
    settings.ensure_dirs()
    store = JobStore(settings)
    opened = []
    app = create_app(settings, engine=FakeEngine(settings), store=store)
    # route the "open folder" action to a recorder instead of launching a file manager
    monkeypatch.setattr(desktop, "open_folder", lambda path: opened.append(path))
    with TestClient(app, base_url="http://127.0.0.1:8000") as client:
        yield type("Env", (), dict(settings=settings, store=store, client=client, home=home, opened=opened))


def completed_job(env, content=b"x" * 3000, title="Clip"):
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    env.store.claim_next("w1")
    jobdir = env.settings.jobs_dir / job.id
    jobdir.mkdir(parents=True)
    (jobdir / "media.mp4").write_bytes(content)
    now = time.time()
    env.store.update(job.id, "w1", status=JobStatus.COMPLETED, filename=f"{title}.mp4", output_name="media.mp4",
                     output_size=len(content), completed_at=now, expires_at=now + 60)
    return job


# ------------------------------------------------------------ host / header guards

@pytest.mark.parametrize("host, expected", [
    ("localhost", True), ("localhost:8000", True), ("127.0.0.1:54321", True), ("[::1]:8000", True),
    ("LOCALHOST:80", True), ("evil.example", False), ("evil.example:8000", False), ("127.0.0.1.evil.example", False),
    ("localhost.evil.example:8000", False), ("", False), (None, False), ("192.168.1.5:8000", False),
])
def test_host_header_allowlist(host, expected):
    assert desktop.host_is_local(host) is expected


def test_dns_rebinding_requests_are_rejected_for_the_whole_api(env):
    for path in ("/health/live", "/api/v1/downloads/metadata", f"{BASE}/preferences"):
        response = env.client.get(path, headers={"Host": "attacker.example:8000"})
        assert response.status_code == 403, path
    assert env.client.get("/health/live").status_code == 200


def test_desktop_endpoints_need_the_custom_header_that_forces_a_cors_preflight(env):
    assert env.client.get(f"{BASE}/preferences").status_code == 401
    assert env.client.post(f"{BASE}/open-folder").status_code == 401
    assert env.client.get(f"{BASE}/preferences", headers={"X-Namao-Desktop": "0"}).status_code == 401
    assert env.client.get(f"{BASE}/preferences", headers=HDR).status_code == 200


def test_desktop_routes_do_not_exist_outside_desktop_mode(settings):
    settings.ensure_dirs()
    app = create_app(settings, engine=FakeEngine(settings), store=JobStore(settings))
    with TestClient(app) as client:
        assert client.get(f"{BASE}/preferences", headers=HDR).status_code == 404


def test_no_cors_headers_are_ever_served_to_other_origins(env):
    response = env.client.get(f"{BASE}/preferences", headers={**HDR, "Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in {k.lower() for k in response.headers}


# ------------------------------------------------------------- folder validation

def test_output_folder_must_be_inside_the_home_directory(home):
    inside = home / "Videos" / "Namao"
    assert desktop.validate_output_dir(str(inside)) == inside.resolve()
    for bad in (str(home), str(home.parent), str(home / ".." / "elsewhere"), str(home / ".ssh"),
                str(home / "Videos" / ".hidden"), "relative/folder", "", "   ", "x" * 600, "a\x00b",
                "C:\\Windows\\System32" if __import__("os").name == "nt" else "/etc"):
        with pytest.raises(NamaoError):
            desktop.validate_output_dir(bad)


def test_non_string_folder_values_are_rejected(home):
    with pytest.raises(NamaoError):
        desktop.validate_output_dir(None)  # type: ignore[arg-type]


def test_preferences_default_then_persist(env):
    first = env.client.get(f"{BASE}/preferences", headers=HDR).json()
    assert first["output_dir"].endswith("Namao") and first["auto_save"] is True
    target = env.home / "Movies" / "MyNamao"
    saved = env.client.put(f"{BASE}/preferences", headers=HDR, json={"output_dir": str(target), "auto_save": False})
    assert saved.status_code == 200 and target.is_dir()
    again = env.client.get(f"{BASE}/preferences", headers=HDR).json()
    assert again["output_dir"] == str(target.resolve()) and again["auto_save"] is False


def test_invalid_preference_values_are_refused_and_do_not_change_anything(env):
    before = env.client.get(f"{BASE}/preferences", headers=HDR).json()
    for body in ({"output_dir": "/etc"}, {"output_dir": str(env.home)}, {"output_dir": str(env.home / ".config")},
                 {"output_dir": "x", "extra": 1}, {}):
        assert env.client.put(f"{BASE}/preferences", headers=HDR, json=body).status_code in (400, 422)
    assert env.client.get(f"{BASE}/preferences", headers=HDR).json() == before


def test_a_corrupt_or_tampered_preferences_file_falls_back_to_the_default(env):
    (env.settings.data_dir / "preferences.json").write_text('{"output_dir": "/etc", "auto_save": true}')
    assert env.client.get(f"{BASE}/preferences", headers=HDR).json()["output_dir"].endswith("Namao")
    (env.settings.data_dir / "preferences.json").write_text("not json")
    assert env.client.get(f"{BASE}/preferences", headers=HDR).status_code == 200


# --------------------------------------------------------------------- saving

def test_save_copies_the_file_and_never_overwrites_an_existing_one(env):
    job = completed_job(env, content=b"first" * 800, title="My Clip")
    first = env.client.post(f"{BASE}/jobs/{job.id}/save", headers=HDR).json()
    second = env.client.post(f"{BASE}/jobs/{job.id}/save", headers=HDR).json()
    assert first["saved"] and first["name"] == "My Clip.mp4" and second["name"] == "My Clip (1).mp4"
    folder = Path(first["folder"])
    assert (folder / "My Clip.mp4").read_bytes() == b"first" * 800 == (folder / "My Clip (1).mp4").read_bytes()
    assert not any(p.name.startswith(".") for p in folder.iterdir()), "no temp files left behind"


def test_save_never_replaces_a_users_existing_file(env):
    preferred = Path(env.client.get(f"{BASE}/preferences", headers=HDR).json()["output_dir"])
    preferred.mkdir(parents=True)
    (preferred / "Clip.mp4").write_bytes(b"PRECIOUS")
    job = completed_job(env, title="Clip")
    saved = env.client.post(f"{BASE}/jobs/{job.id}/save", headers=HDR).json()
    assert (preferred / "Clip.mp4").read_bytes() == b"PRECIOUS" and saved["name"] == "Clip (1).mp4"


def test_save_requires_a_completed_unexpired_job(env):
    done = completed_job(env)  # (claim_next takes the oldest queued job, so create this one first)
    env.store.mark_files_deleted(done.id)
    assert env.client.post(f"{BASE}/jobs/{done.id}/save", headers=HDR).status_code == 410
    queued, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    assert env.client.post(f"{BASE}/jobs/{queued.id}/save", headers=HDR).status_code == 409
    assert env.client.post(f"{BASE}/jobs/{'z' * 24}/save", headers=HDR).status_code == 404


def test_concurrent_saves_of_the_same_name_get_distinct_files(tmp_path):
    source = tmp_path / "src.mp4"
    source.write_bytes(b"d" * 4096)
    folder = tmp_path / "out"
    results = []

    def save():
        results.append(desktop.copy_without_overwriting(source, folder, "Same.mp4").name)

    threads = [threading.Thread(target=save) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(set(results)) == 8 and len(list(folder.iterdir())) == 8


def test_open_folder_opens_only_the_configured_output_folder(env):
    response = env.client.post(f"{BASE}/open-folder", headers=HDR)
    assert response.status_code == 200 and len(env.opened) == 1
    assert env.opened[0].name == "Namao" and env.home in env.opened[0].parents
    assert env.client.post(f"{BASE}/open-folder", headers=HDR, json={"path": "/etc"}).status_code == 200
    assert all(p.name == "Namao" for p in env.opened), "a client-supplied path is ignored"


# ------------------------------------------------------------ per-user token

@pytest.fixture()
def secured(settings, home, monkeypatch):
    monkeypatch.setattr("namao.security.socket.getaddrinfo", lambda *a, **k: [(2, 1, 6, "", ("142.250.72.14", 0))])
    settings = settings.with_overrides(desktop_mode=True, desktop_token="t" * 24)
    settings.ensure_dirs()
    app = create_app(settings, engine=FakeEngine(settings), store=JobStore(settings))
    with TestClient(app, base_url="http://127.0.0.1:8000", follow_redirects=False) as client:
        yield client


def test_without_the_launcher_token_nothing_but_liveness_is_reachable(secured):
    assert secured.get("/health/live").status_code == 200
    for path in ("/", "/app.js", "/health/ready", "/api/v1/desktop/preferences"):
        assert secured.get(path, headers=HDR).status_code == 403, path
    assert secured.get("/?t=wrong").status_code == 403


def test_the_launcher_token_becomes_an_httponly_strict_cookie_and_leaves_the_url(secured):
    first = secured.get("/?t=" + "t" * 24)
    assert first.status_code == 303 and first.headers["location"] == "/"
    cookie = first.headers["set-cookie"].lower()
    assert "namao_desktop=" in cookie and "httponly" in cookie and "samesite=strict" in cookie
    assert secured.get("/").status_code == 200  # the client now carries the cookie
    assert secured.get("/api/v1/desktop/preferences", headers=HDR).status_code == 200


def test_a_malformed_or_rewritten_cookie_is_refused(secured):
    secured.cookies.set("namao_desktop", "x" * 24)
    assert secured.get("/").status_code == 403


def test_launcher_token_is_private_stable_and_used_in_the_ui_url(tmp_path, monkeypatch):
    import importlib
    launcher = importlib.import_module("launcher")
    first = launcher.load_or_create_token(tmp_path)
    assert len(first) >= 20 and launcher.load_or_create_token(tmp_path) == first
    monkeypatch.setenv("NAMAO_DESKTOP_TOKEN", first)
    assert launcher.ui_url(8123) == f"http://127.0.0.1:8123/?t={first}"


# -------------------------------------------------- review follow-ups

@pytest.mark.parametrize("host", ["[::1]junk", "localhost:notaport", "localhost:", "127.0.0.1.", "localhost.",
                                  "localhost:99999999", "127.0.0.1:80:80", "local host"])
def test_host_header_regex_is_strict(host):
    assert desktop.host_is_local(host) is False


def test_application_support_folders_are_not_valid_download_folders(home):
    for reserved in ("AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup", "appdata/local/x",
                     "Library/LaunchAgents", "library"):
        with pytest.raises(NamaoError):
            desktop.validate_output_dir(str(home / reserved))


def test_a_non_object_preferences_file_falls_back_to_defaults(env):
    (env.settings.data_dir / "preferences.json").write_text("[]")
    response = env.client.get(f"{BASE}/preferences", headers=HDR)
    assert response.status_code == 200 and response.json()["output_dir"].endswith("Namao")


def test_a_dangling_symlink_occupies_its_name(tmp_path):
    folder = tmp_path / "out"
    folder.mkdir()
    try:
        (folder / "Clip.mp4").symlink_to(tmp_path / "does-not-exist")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable")
    assert desktop.unique_destination(folder, "Clip.mp4").name == "Clip (1).mp4"


def test_the_no_hardlink_fallback_never_deletes_a_file_it_did_not_create(tmp_path, monkeypatch):
    source = tmp_path / "src.mp4"
    source.write_bytes(b"d" * 2048)
    folder = tmp_path / "out"
    folder.mkdir()
    precious = folder / "Clip.mp4"
    precious.write_bytes(b"MINE")
    monkeypatch.setattr(desktop.os, "link", lambda *a, **k: (_ for _ in ()).throw(OSError("no hard links")))
    saved = desktop.copy_without_overwriting(source, folder, "Clip.mp4")
    assert saved.name == "Clip (1).mp4" and precious.read_bytes() == b"MINE"
    assert not any(p.name.startswith(".namao-") for p in folder.iterdir())
