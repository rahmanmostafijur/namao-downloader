"""Structured (JSON) logging with secret redaction.

All log text passes through `errors.redact`, so signed media URLs and
filesystem paths never reach the logs even when they appear inside a third
party exception message.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time

from .errors import redact

_STANDARD_ATTRS = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + "Z",
            "level": record.levelname,
            "logger": record.name,
            "msg": redact(record.getMessage()),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD_ATTRS and not key.startswith("_"):
                payload[key] = value if isinstance(value, (int, float, bool, type(None))) else redact(str(value))
        if record.exc_info:
            # Class name only: tracebacks can embed URLs, paths and tokens.
            payload["exc"] = record.exc_info[0].__name__ if record.exc_info[0] else None
        return json.dumps(payload, default=str, ensure_ascii=False)


def configure_logging(level: str | None = None) -> None:
    level = level or os.environ.get("NAMAO_LOG_LEVEL", "INFO")
    root = logging.getLogger()
    if any(getattr(h, "_namao", False) for h in root.handlers):
        return
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    handler._namao = True  # type: ignore[attr-defined]
    root.addHandler(handler)
    root.setLevel(level.upper())


def log_event(logger: logging.Logger, event: str, **fields) -> None:
    logger.info(event, extra=fields)
