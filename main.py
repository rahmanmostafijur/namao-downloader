"""ASGI entry point: `uvicorn main:app` (kept for backwards compatibility).

All code lives in the `namao` package. The API only manages jobs; downloads
run in `python -m namao.worker` (or in-process with NAMAO_EMBEDDED_WORKER=1).
"""

from namao.api.app import create_app

app = create_app()
