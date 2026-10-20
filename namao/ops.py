"""Operator commands: `python -m namao.ops status | drain [--wait SECONDS] | resume`.

Safe-update procedure (see docs/deployment.md):
    docker compose exec api python -m namao.ops drain --wait 1800
    docker compose up -d --build            # new image, new yt-dlp pin
    docker compose exec api python -m namao.ops resume

`drain` makes workers stop claiming jobs (running ones finish); it exits 0 once
no job is active, 2 if the wait ran out first.
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from .config import Settings, load_settings
from .jobs.store import JobStore
from .models import ACTIVE_STATUSES, TERMINAL_STATUSES


def snapshot(settings: Settings, store: JobStore) -> dict:
    with store._connect() as conn:  # read-only aggregate; ops is part of the persistence layer's contract
        counts = {r["status"]: r["n"] for r in conn.execute("SELECT status, COUNT(*) AS n FROM jobs GROUP BY status")}
    active = sum(n for status, n in counts.items() if status in {s.value for s in ACTIVE_STATUSES})
    queued = counts.get("queued", 0)
    return {
        "draining": settings.drain_file.exists(),
        "active_jobs": active,
        "queued_jobs": queued,
        "finished_jobs": sum(n for status, n in counts.items() if status in {s.value for s in TERMINAL_STATUSES}),
        "workers_alive": store.alive_worker_count(settings.stale_after_seconds),
    }


def drain(settings: Settings, store: JobStore, wait_seconds: float, poll: float = 2.0) -> int:
    settings.ensure_dirs()
    settings.drain_file.write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), encoding="utf-8")
    deadline = time.monotonic() + wait_seconds
    while True:
        if snapshot(settings, store)["active_jobs"] == 0:
            return 0
        if time.monotonic() >= deadline:
            return 2
        time.sleep(poll)


def resume(settings: Settings) -> None:
    settings.drain_file.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m namao.ops", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="print job/worker counts as JSON")
    drain_parser = sub.add_parser("drain", help="stop claiming jobs; optionally wait for running ones")
    drain_parser.add_argument("--wait", type=float, default=0.0, metavar="SECONDS")
    sub.add_parser("resume", help="leave drain mode")
    args = parser.parse_args(argv)

    settings = load_settings()
    store = JobStore(settings)
    if args.command == "status":
        print(json.dumps(snapshot(settings, store), indent=2))
        return 0
    if args.command == "drain":
        code = drain(settings, store, args.wait)
        print(json.dumps(snapshot(settings, store), indent=2))
        if code:
            print("still active jobs after the wait", file=sys.stderr)
        return code
    resume(settings)
    print(json.dumps(snapshot(settings, store), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
