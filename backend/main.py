"""
Ollama Monitor Backend - FastAPI server
- Proxies Ollama REST API (avoids CORS)
- Tails BOTH app.log and server.log concurrently
- Collects system metrics (CPU, RAM, GPU)
- Broadcasts live updates over WebSocket
- Persists data to SQLite (monitor.db)
- Password-based authentication
"""

import asyncio
import platform

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import database as db
from config import LOG_PATHS, SERVERS
from logs import _make_entry, tail_log_file, tail_log_journald
from poller import poller
from routers import auth, history, monitor, ws
from state import _valid_tokens, log_lines, recent_requests

app = FastAPI(title="Ollama Monitor", version="1.3.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

app.include_router(auth.router)
app.include_router(monitor.router)
app.include_router(history.router)
app.include_router(ws.router)


@app.on_event("startup")
async def startup():
    db.init_db()
    _valid_tokens.update(db.load_all_tokens())
    for r in reversed(db.get_request_history(hours=24, limit=200)):
        recent_requests.append(r)
    for entry in reversed(db.get_log_history(hours=24, limit=200)):
        log_lines.append({"ts": entry["ts"], "text": entry["text"],
                          "source": entry.get("source", "server"),
                          "level": entry.get("level", "info"),
                          "server_id": entry.get("server_id", "default")})
    asyncio.create_task(poller())
    # Log files are local so we associate them with the first (local) server
    local_server_id = SERVERS[0]["id"]
    if LOG_PATHS:
        for log_path, label in LOG_PATHS:
            asyncio.create_task(tail_log_file(log_path, label, local_server_id))
    elif platform.system() == "Linux":
        asyncio.create_task(tail_log_journald(local_server_id))
    else:
        entry = _make_entry("[monitor] No Ollama log files found. Set OLLAMA_APP_LOG or OLLAMA_SERVER_LOG.",
                            "server", local_server_id)
        log_lines.append(entry)
        db.insert_log(entry)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=12434, reload=False)
