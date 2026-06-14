import asyncio
import time
from datetime import datetime, timezone

import database as db
from config import LOG_KEEP_DAYS, POLL_INTERVAL, PRUNE_INTERVAL, SERVERS
from metrics import get_system_metrics
from ollama import ollama_get
import state
from state import recent_requests
from websocket import broadcast


async def _poll_server(server: dict, system: dict | None, is_first: bool) -> None:
    server_id = server["id"]
    base_url  = server["url"]

    try:
        running_models = (await ollama_get("/api/ps", base_url=base_url)).get("models", [])
    except Exception:
        running_models = []

    state.server_running_models[server_id] = running_models
    if is_first:
        state.running_models[:] = running_models   # backward compat

    try:
        ollama_version = (await ollama_get("/api/version", base_url=base_url)).get("version", "unknown")
    except Exception:
        ollama_version = "offline"

    # System metrics are from the monitor host (not the remote Ollama server).
    # Include them only for the first server to avoid duplication in multi-server setups.
    snap = {
        "ts":              datetime.now(timezone.utc).isoformat(),
        "system":          system if is_first else None,
        "running_models":  running_models,
        "ollama_version":  ollama_version,
        "recent_requests": [r for r in list(recent_requests)[-50:]
                            if r.get("server_id", "default") == server_id],
        "server_id":       server_id,
    }
    db.insert_metrics(snap)
    await broadcast({"type": "metrics", "server_id": server_id, "data": snap})


async def poller():
    last_prune = time.time()
    while True:
        try:
            system = get_system_metrics()
            tasks = [
                _poll_server(server, system, i == 0)
                for i, server in enumerate(SERVERS)
            ]
            await asyncio.gather(*tasks, return_exceptions=True)

            if time.time() - last_prune > PRUNE_INTERVAL:
                db.prune_old_data(keep_days=LOG_KEEP_DAYS)
                last_prune = time.time()
        except Exception:
            pass
        await asyncio.sleep(POLL_INTERVAL)
