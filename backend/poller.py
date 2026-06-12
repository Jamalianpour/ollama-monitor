import asyncio
import time
from datetime import datetime, timezone

import database as db
from config import LOG_KEEP_DAYS, POLL_INTERVAL, PRUNE_INTERVAL
from metrics import get_system_metrics
from ollama import ollama_get
import state
from state import recent_requests
from websocket import broadcast


async def poller():
    last_prune = time.time()
    while True:
        try:
            system = get_system_metrics()
            try:
                running_models = (await ollama_get("/api/ps")).get("models", [])
                state.running_models[:] = running_models
            except Exception:
                running_models = []
            try:
                ollama_version = (await ollama_get("/api/version")).get("version", "unknown")
            except Exception:
                ollama_version = "offline"
            snap = {"ts": datetime.now(timezone.utc).isoformat(), "system": system,
                    "running_models": running_models, "ollama_version": ollama_version,
                    "recent_requests": list(recent_requests)[-50:]}
            db.insert_metrics(snap)
            await broadcast({"type": "metrics", "data": snap})
            if time.time() - last_prune > PRUNE_INTERVAL:
                db.prune_old_data(keep_days=LOG_KEEP_DAYS)
                last_prune = time.time()
        except Exception:
            pass
        await asyncio.sleep(POLL_INTERVAL)
