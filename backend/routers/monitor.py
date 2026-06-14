from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

import database as db
from auth import require_auth
from config import LOG_PATHS, OLLAMA_BASE, SERVERS
from metrics import get_system_metrics
from ollama import ollama_get
from state import log_lines, recent_requests
from websocket import broadcast

router = APIRouter(tags=["monitor"])


@router.get("/api/servers")
async def list_servers(_: str = Depends(require_auth)):
    return {"servers": [{"id": s["id"], "name": s["name"], "url": s["url"]} for s in SERVERS]}


@router.get("/api/health")
async def health(_: str = Depends(require_auth)):
    return {
        "status": "ok",
        "log_files": [{"path": str(p), "label": lbl, "exists": p.exists()} for p, lbl in LOG_PATHS],
        "ollama_host": OLLAMA_BASE,
        "db_path": str(db._db_path()),
    }


@router.get("/api/system")
async def system_metrics(_: str = Depends(require_auth)):
    return get_system_metrics()


@router.get("/api/models")
async def list_models(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/tags")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@router.get("/api/ps")
async def running_models(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/ps")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@router.get("/api/version")
async def ollama_version(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/version")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@router.get("/api/logs")
async def get_logs(limit: int = 200, source: Optional[str] = None, _: str = Depends(require_auth)):
    lines = list(log_lines)
    if source:
        lines = [ln for ln in lines if ln.get("source") == source]
    return {
        "lines": lines[-limit:],
        "log_files": [{"path": str(p), "label": lbl} for p, lbl in LOG_PATHS],
    }


@router.get("/api/requests")
async def get_requests(limit: int = 100, _: str = Depends(require_auth)):
    return {"requests": list(recent_requests)[-limit:]}


@router.post("/api/requests")
async def record_request(req: dict, _: str = Depends(require_auth)):
    req.setdefault("ts", datetime.now(timezone.utc).isoformat())
    recent_requests.append(req)
    db.insert_request(req)
    await broadcast({"type": "request", "data": req})
    return {"ok": True}
