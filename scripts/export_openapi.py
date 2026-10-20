#!/usr/bin/env python3
"""Regenerate docs/openapi.json from the running application's own schema.

    python scripts/export_openapi.py

tests/test_api.py fails when the committed file is stale, so the documented API
cannot drift from the code.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from namao.api.app import create_app  # noqa: E402
from namao.config import Settings  # noqa: E402


def main() -> int:
    with tempfile.TemporaryDirectory() as scratch:
        schema = create_app(Settings(data_dir=Path(scratch))).openapi()
    target = ROOT / "docs" / "openapi.json"
    target.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {target.relative_to(ROOT)} ({len(schema['paths'])} paths)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
