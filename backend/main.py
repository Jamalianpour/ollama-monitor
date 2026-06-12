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
import json
import os
import platform
import secrets
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import bcrypt
import httpx
import psutil
from fastapi import Depends, FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

import database as db

# --- Auth -------------------------------------------------------------------

_valid_tokens: set[str] = set()
_bearer = HTTPBearer(auto_error=False)


def _is_valid_token(token: str) -> bool:
    return bool(token) and token in _valid_tokens


def require_auth(credentials: HTTPAuthorizationCredentials = Depends(_bearer)):
    if credentials is None or not _is_valid_token(credentials.credentials):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or missing token")
    return credentials.credentials


# --- Config -----------------------------------------------------------------

OLLAMA_BASE    = os.getenv("OLLAMA_HOST", "http://localhost:11434")
POLL_INTERVAL  = float(os.getenv("POLL_INTERVAL", "2"))
PRUNE_INTERVAL = 3600
LOG_KEEP_DAYS  = int(os.getenv("LOG_KEEP_DAYS", "7"))


def default_log_paths() -> list[tuple[Path, str]]:
    """
    Returns a list of (path, label) pairs for all Ollama log files that exist.
    Label is 'app' or 'server' so UI can distinguish them.
    """
    system = platform.system()
    candidates: list[tuple[Path, str]] = []

    if system == "Windows":
        appdata = os.getenv("LOCALAPPDATA", "")
        base = Path(appdata) / "Ollama"
        candidates = [
            (base / "app.log",    "app"),
            (base / "server.log", "server"),
        ]
    elif system == "Linux":
        home = Path.home()
        candidates = [
            (home / ".ollama" / "logs" / "server.log", "server"),
            (Path("/var/log/ollama.log"),               "server"),
        ]
    elif system == "Darwin":
        home = Path.home()
        candidates = [
            (home / ".ollama" / "logs" / "server.log", "server"),
            (home / ".ollama" / "logs" / "app.log",    "app"),
        ]

    found = [(p, label) for p, label in candidates if p.exists()]

    # Allow overrides via env vars
    if os.getenv("OLLAMA_APP_LOG"):
        found.append((Path(os.environ["OLLAMA_APP_LOG"]), "app"))
    if os.getenv("OLLAMA_SERVER_LOG"):
        found.append((Path(os.environ["OLLAMA_SERVER_LOG"]), "server"))
    if os.getenv("OLLAMA_LOG"):
        found.append((Path(os.environ["OLLAMA_LOG"]), "server"))

    return found


LOG_PATHS: list[tuple[Path, str]] = default_log_paths()

# --- In-memory buffers ------------------------------------------------------

recent_requests: deque = deque(maxlen=200)
log_lines: deque = deque(maxlen=500)
connected_clients: list[WebSocket] = []

# --- App --------------------------------------------------------------------

app = FastAPI(title="Ollama Monitor", version="1.3.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# --- Helpers ----------------------------------------------------------------

async def ollama_get(path: str) -> dict:
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.get(f"{OLLAMA_BASE}{path}")
        r.raise_for_status()
        return r.json()


def get_gpu_metrics() -> list[dict]:
    metrics = []
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            timeout=3, stderr=subprocess.DEVNULL).decode()
        for i, line in enumerate(out.strip().splitlines()):
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                metrics.append({"index": i, "name": parts[0], "vendor": "nvidia",
                                 "utilization_pct": float(parts[1]), "memory_used_mb": float(parts[2]),
                                 "memory_total_mb": float(parts[3]), "temperature_c": float(parts[4])})
        if metrics:
            return metrics
    except Exception:
        pass
    try:
        out = subprocess.check_output(
            ["rocm-smi", "--showuse", "--showmeminfo", "vram", "--json"],
            timeout=3, stderr=subprocess.DEVNULL).decode()
        data = json.loads(out)
        for i, (key, val) in enumerate(data.items()):
            if key.startswith("card"):
                metrics.append({"index": i, "name": val.get("Card series", key), "vendor": "amd",
                                 "utilization_pct": float(val.get("GPU use (%)", 0)),
                                 "memory_used_mb": float(val.get("VRAM Total Used Memory (B)", 0)) / 1024 / 1024,
                                 "memory_total_mb": float(val.get("VRAM Total Memory (B)", 0)) / 1024 / 1024,
                                 "temperature_c": None})
        if metrics:
            return metrics
    except Exception:
        pass
    return []


def get_system_metrics() -> dict:
    cpu = psutil.cpu_percent(interval=None)
    vm = psutil.virtual_memory()
    disk = psutil.disk_usage("/") if platform.system() != "Windows" else psutil.disk_usage("C:\\")
    return {"cpu_pct": cpu, "ram_used_gb": vm.used / 1e9, "ram_total_gb": vm.total / 1e9,
            "ram_pct": vm.percent, "disk_used_gb": disk.used / 1e9, "disk_total_gb": disk.total / 1e9,
            "disk_pct": disk.percent, "gpus": get_gpu_metrics()}


# --- Log helpers ------------------------------------------------------------

def _level_from_line(text: str) -> str:
    """Extract log level from structured Ollama log lines."""
    lower = text.lower()
    # Structured format: level=ERROR or level=WARN etc.
    for marker, level in [("level=error", "error"), ("level=warn", "warn"),
                           ("level=fatal", "error"), ("level=debug", "debug")]:
        if marker in lower:
            return level
    # GIN format: status codes
    if " | 4" in text or " | 5" in text:
        return "warn"
    if "error" in lower or "fatal" in lower:
        return "error"
    if "warn" in lower:
        return "warn"
    return "info"


def _should_persist_log(text: str, label: str) -> bool:
    lower = text.lower()
    return any(kw in lower for kw in
               ("error", "warn", "fatal", "loaded", "unloaded", "starting",
                "listening", "inference compute", "skipping", "discovering"))


def _make_entry(text: str, label: str) -> dict:
    return {
        "ts":     datetime.now(timezone.utc).isoformat(),
        "text":   text,
        "source": label,
        "level":  _level_from_line(text),
    }


# --- Log tail ---------------------------------------------------------------

async def tail_log_file(log_path: Path, label: str):
    """Tail a single log file, tagging each entry with label ('app' or 'server')."""
    if not log_path.exists():
        entry = _make_entry(f"[monitor] Log not found: {log_path}", label)
        log_lines.append(entry)
        db.insert_log(entry)
        return

    # Seed recent history into memory buffer
    try:
        with open(log_path, "r", errors="replace") as f:
            for line in f.readlines()[-100:]:
                log_lines.append(_make_entry(line.rstrip(), label))
    except Exception as e:
        log_lines.append(_make_entry(f"[monitor] Seed error ({label}): {e}", label))

    # Live tail
    try:
        with open(log_path, "r", errors="replace") as f:
            f.seek(0, 2)
            while True:
                line = f.readline()
                if line:
                    entry = _make_entry(line.rstrip(), label)
                    log_lines.append(entry)
                    if _should_persist_log(line, label):
                        db.insert_log(entry)
                    await broadcast({"type": "log", "data": entry})
                else:
                    await asyncio.sleep(0.2)
    except Exception as e:
        entry = _make_entry(f"[monitor] Tail error ({label}): {e}", label)
        log_lines.append(entry)
        db.insert_log(entry)


async def tail_log_journald():
    """Fallback for Linux systems without a log file."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "journalctl", "-u", "ollama", "-f", "-n", "100", "--no-pager",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").rstrip()
            entry = _make_entry(line, "server")
            log_lines.append(entry)
            if _should_persist_log(line, "server"):
                db.insert_log(entry)
            await broadcast({"type": "log", "data": entry})
    except Exception as e:
        entry = _make_entry(f"[monitor] journalctl error: {e}", "server")
        log_lines.append(entry)
        db.insert_log(entry)


# --- Broadcast --------------------------------------------------------------

async def broadcast(msg: dict):
    dead = []
    text = json.dumps(msg)
    for ws in connected_clients:
        try:
            await ws.send_text(text)
        except Exception:
            dead.append(ws)
    for ws in dead:
        connected_clients.remove(ws)


# --- Poller -----------------------------------------------------------------

async def poller():
    last_prune = time.time()
    while True:
        try:
            system = get_system_metrics()
            try:
                running_models = (await ollama_get("/api/ps")).get("models", [])
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


# --- Startup ----------------------------------------------------------------

@app.on_event("startup")
async def startup():
    db.init_db()
    _valid_tokens.update(db.load_all_tokens())
    for r in reversed(db.get_request_history(hours=24, limit=200)):
        recent_requests.append(r)
    for entry in reversed(db.get_log_history(hours=24, limit=200)):
        log_lines.append({"ts": entry["ts"], "text": entry["text"],
                          "source": entry.get("source", "server"),
                          "level": entry.get("level", "info")})
    asyncio.create_task(poller())
    if LOG_PATHS:
        for log_path, label in LOG_PATHS:
            asyncio.create_task(tail_log_file(log_path, label))
    elif platform.system() == "Linux":
        asyncio.create_task(tail_log_journald())
    else:
        entry = _make_entry("[monitor] No Ollama log files found. Set OLLAMA_APP_LOG or OLLAMA_SERVER_LOG.", "server")
        log_lines.append(entry)
        db.insert_log(entry)


# --- Auth endpoints (no token required) -------------------------------------

@app.get("/api/auth/status")
async def auth_status():
    return {"password_set": db.get_setting("password_hash") is not None}


@app.post("/api/auth/setup")
async def auth_setup(body: dict):
    if db.get_setting("password_hash") is not None:
        raise HTTPException(status_code=409, detail="Password already configured")
    password = body.get("password", "")
    if len(password) < 8:
        raise HTTPException(status_code=422, detail="Password must be at least 8 characters")
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    db.set_setting("password_hash", hashed)
    token = secrets.token_urlsafe(32)
    _valid_tokens.add(token)
    db.create_session(token)
    return {"token": token}


@app.post("/api/auth/login")
async def auth_login(body: dict):
    password = body.get("password", "")
    stored = db.get_setting("password_hash")
    if stored is None:
        raise HTTPException(status_code=403, detail="No password configured yet")
    if not bcrypt.checkpw(password.encode(), stored.encode()):
        raise HTTPException(status_code=401, detail="Incorrect password")
    token = secrets.token_urlsafe(32)
    _valid_tokens.add(token)
    db.create_session(token)
    return {"token": token}


@app.post("/api/auth/logout")
async def auth_logout(token: str = Depends(require_auth)):
    _valid_tokens.discard(token)
    db.delete_session(token)
    return {"ok": True}


@app.post("/api/auth/change-password")
async def auth_change_password(body: dict, token: str = Depends(require_auth)):
    current = body.get("current_password", "")
    new_pass = body.get("new_password", "")
    stored = db.get_setting("password_hash")
    if not stored or not bcrypt.checkpw(current.encode(), stored.encode()):
        raise HTTPException(status_code=401, detail="Current password is incorrect")
    if len(new_pass) < 8:
        raise HTTPException(status_code=422, detail="New password must be at least 8 characters")
    hashed = bcrypt.hashpw(new_pass.encode(), bcrypt.gensalt()).decode()
    db.set_setting("password_hash", hashed)
    _valid_tokens.clear()
    db.delete_all_sessions()
    new_token = secrets.token_urlsafe(32)
    _valid_tokens.add(new_token)
    db.create_session(new_token)
    return {"token": new_token}


# --- REST endpoints (auth required) -----------------------------------------

@app.get("/api/health")
async def health(_: str = Depends(require_auth)):
    return {
        "status": "ok",
        "log_files": [{"path": str(p), "label": lbl, "exists": p.exists()} for p, lbl in LOG_PATHS],
        "ollama_host": OLLAMA_BASE,
        "db_path": str(db._db_path()),
    }


@app.get("/api/system")
async def system_metrics(_: str = Depends(require_auth)):
    return get_system_metrics()


@app.get("/api/models")
async def list_models(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/tags")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@app.get("/api/ps")
async def running_models(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/ps")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@app.get("/api/version")
async def ollama_version(_: str = Depends(require_auth)):
    try:
        return await ollama_get("/api/version")
    except Exception as e:
        return JSONResponse(status_code=502, content={"error": str(e)})


@app.get("/api/logs")
async def get_logs(limit: int = 200, source: Optional[str] = None, _: str = Depends(require_auth)):
    lines = list(log_lines)
    if source:
        lines = [l for l in lines if l.get("source") == source]
    return {
        "lines": lines[-limit:],
        "log_files": [{"path": str(p), "label": lbl} for p, lbl in LOG_PATHS],
    }


@app.get("/api/requests")
async def get_requests(limit: int = 100, _: str = Depends(require_auth)):
    return {"requests": list(recent_requests)[-limit:]}


@app.post("/api/requests")
async def record_request(req: dict, _: str = Depends(require_auth)):
    req.setdefault("ts", datetime.now(timezone.utc).isoformat())
    recent_requests.append(req)
    db.insert_request(req)
    await broadcast({"type": "request", "data": req})
    return {"ok": True}


# --- History endpoints (auth required) --------------------------------------

@app.get("/api/history/metrics")
async def history_metrics(hours: float = Query(24), limit: int = Query(2000), _: str = Depends(require_auth)):
    return {"rows": db.get_metrics_history(hours=hours, limit=limit)}


@app.get("/api/history/requests")
async def history_requests(hours: float = Query(24), limit: int = Query(1000), _: str = Depends(require_auth)):
    return {"requests": db.get_request_history(hours=hours, limit=limit)}


@app.get("/api/history/logs")
async def history_logs(hours: float = Query(24), level: Optional[str] = Query(None),
                       source: Optional[str] = Query(None),
                       limit: int = Query(2000), _: str = Depends(require_auth)):
    return {"lines": db.get_log_history(hours=hours, level=level, source=source, limit=limit)}


@app.get("/api/stats")
async def stats(hours: float = Query(24), _: str = Depends(require_auth)):
    return {"hours": hours, "metrics": db.get_metrics_stats(hours=hours), "requests": db.get_request_stats(hours=hours)}


# --- WebSocket (token as query param) ---------------------------------------

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket, token: str = ""):
    if not _is_valid_token(token):
        await ws.close(code=4001, reason="Unauthorized")
        return
    await ws.accept()
    connected_clients.append(ws)
    await ws.send_text(json.dumps({
        "type": "init",
        "data": {
            "logs": list(log_lines)[-100:],
            "requests": list(recent_requests)[-50:],
            "log_files": [{"path": str(p), "label": lbl} for p, lbl in LOG_PATHS],
            "ollama_host": OLLAMA_BASE,
        },
    }))
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        if ws in connected_clients:
            connected_clients.remove(ws)


# --- Entry point ------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8765, reload=False)
