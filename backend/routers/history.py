from typing import Optional

from fastapi import APIRouter, Depends, Query

import database as db
from auth import require_auth

router = APIRouter(tags=["history"])


@router.get("/api/history/metrics")
async def history_metrics(hours: float = Query(24), limit: int = Query(2000), _: str = Depends(require_auth)):
    return {"rows": db.get_metrics_history(hours=hours, limit=limit)}


@router.get("/api/history/requests")
async def history_requests(hours: float = Query(24), limit: int = Query(1000), _: str = Depends(require_auth)):
    return {"requests": db.get_request_history(hours=hours, limit=limit)}


@router.get("/api/history/logs")
async def history_logs(hours: float = Query(24), level: Optional[str] = Query(None),
                       source: Optional[str] = Query(None),
                       limit: int = Query(2000), _: str = Depends(require_auth)):
    return {"lines": db.get_log_history(hours=hours, level=level, source=source, limit=limit)}


@router.get("/api/stats")
async def stats(hours: float = Query(24), _: str = Depends(require_auth)):
    return {"hours": hours, "metrics": db.get_metrics_stats(hours=hours), "requests": db.get_request_stats(hours=hours)}
