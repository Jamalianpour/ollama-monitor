"""
SQLite persistence layer for Ollama Monitor.

Tables:
  metrics_snapshots - system resource readings every poll
  request_records   - per-request latency / token stats
  log_entries       - important log lines (errors, warnings, model events)
  settings          - key/value config (e.g. password_hash)
  sessions          - auth tokens
"""

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

DEFAULT_DB = Path(__file__).parent / "monitor.db"

_local = threading.local()


def _db_path() -> Path:
    import os
    p = os.getenv("MONITOR_DB")
    return Path(p) if p else DEFAULT_DB


def get_conn() -> sqlite3.Connection:
    if not hasattr(_local, "conn") or _local.conn is None:
        path = _db_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        _local.conn = conn
    return _local.conn


def init_db():
    conn = get_conn()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS metrics_snapshots (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            ts            TEXT    NOT NULL,
            cpu_pct       REAL,
            ram_pct       REAL,
            ram_used_gb   REAL,
            ram_total_gb  REAL,
            disk_pct      REAL,
            disk_used_gb  REAL,
            disk_total_gb REAL,
            gpus_json     TEXT DEFAULT '[]',
            running_models_json TEXT DEFAULT '[]',
            ollama_version TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics_snapshots(ts);

        CREATE TABLE IF NOT EXISTS request_records (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            ts          TEXT    NOT NULL,
            model       TEXT    NOT NULL,
            duration_ms INTEGER,
            tokens      INTEGER,
            error       INTEGER DEFAULT 0,
            extra_json  TEXT    DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_req_ts    ON request_records(ts);
        CREATE INDEX IF NOT EXISTS idx_req_model ON request_records(model);

        CREATE TABLE IF NOT EXISTS log_entries (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            ts     TEXT    NOT NULL,
            text   TEXT    NOT NULL,
            level  TEXT    DEFAULT 'info',
            source TEXT    DEFAULT 'server'
        );
        CREATE INDEX IF NOT EXISTS idx_log_ts     ON log_entries(ts);
        CREATE INDEX IF NOT EXISTS idx_log_source ON log_entries(source);

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sessions (
            token      TEXT PRIMARY KEY,
            created_at TEXT NOT NULL
        );
    """)
    conn.commit()


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def insert_metrics(snap: dict):
    sys = snap.get("system") or {}
    conn = get_conn()
    conn.execute(
        """
        INSERT INTO metrics_snapshots
          (ts, cpu_pct, ram_pct, ram_used_gb, ram_total_gb,
           disk_pct, disk_used_gb, disk_total_gb,
           gpus_json, running_models_json, ollama_version)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """,
        (
            snap.get("ts", datetime.now(timezone.utc).isoformat()),
            sys.get("cpu_pct"), sys.get("ram_pct"),
            sys.get("ram_used_gb"), sys.get("ram_total_gb"),
            sys.get("disk_pct"), sys.get("disk_used_gb"), sys.get("disk_total_gb"),
            json.dumps(sys.get("gpus", [])),
            json.dumps(snap.get("running_models", [])),
            snap.get("ollama_version"),
        ),
    )
    conn.commit()


def get_metrics_history(hours: float = 24, limit: int = 2000) -> list[dict]:
    conn = get_conn()
    cutoff = f"datetime('now', '-{hours} hours')"
    rows = conn.execute(
        f"""
        SELECT ts, cpu_pct, ram_pct, ram_used_gb, ram_total_gb,
               disk_pct, disk_used_gb, disk_total_gb,
               gpus_json, running_models_json, ollama_version
        FROM metrics_snapshots
        WHERE ts >= {cutoff}
        ORDER BY ts ASC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    return [dict(r) for r in rows]


def get_metrics_stats(hours: float = 24) -> dict:
    conn = get_conn()
    cutoff = f"datetime('now', '-{hours} hours')"
    row = conn.execute(
        f"""
        SELECT
            AVG(cpu_pct) AS avg_cpu,
            MAX(cpu_pct) AS max_cpu,
            AVG(ram_pct) AS avg_ram,
            MAX(ram_pct) AS max_ram,
            COUNT(*)     AS samples
        FROM metrics_snapshots
        WHERE ts >= {cutoff}
        """
    ).fetchone()
    return dict(row) if row else {}


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

def insert_request(req: dict):
    conn = get_conn()
    extra = {k: v for k, v in req.items() if k not in ("ts", "model", "duration_ms", "tokens", "error")}
    conn.execute(
        "INSERT INTO request_records (ts, model, duration_ms, tokens, error, extra_json) VALUES (?,?,?,?,?,?)",
        (
            req.get("ts", datetime.now(timezone.utc).isoformat()),
            req.get("model", "unknown"),
            req.get("duration_ms"),
            req.get("tokens"),
            1 if req.get("error") else 0,
            json.dumps(extra),
        ),
    )
    conn.commit()


def get_request_history(hours: float = 24, limit: int = 1000) -> list[dict]:
    conn = get_conn()
    cutoff = f"datetime('now', '-{hours} hours')"
    rows = conn.execute(
        f"""
        SELECT ts, model, duration_ms, tokens, error
        FROM request_records
        WHERE ts >= {cutoff}
        ORDER BY ts DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    result = []
    for r in rows:
        d = dict(r)
        d["error"] = bool(d["error"])
        result.append(d)
    return result


def get_request_stats(hours: float = 24) -> dict:
    conn = get_conn()
    cutoff = f"datetime('now', '-{hours} hours')"
    row = conn.execute(
        f"""
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN error=1 THEN 1 ELSE 0 END) AS errors,
            AVG(duration_ms) AS avg_duration_ms,
            MAX(duration_ms) AS max_duration_ms,
            AVG(CAST(tokens AS REAL) * 1000.0 / NULLIF(duration_ms,0)) AS avg_tps
        FROM request_records
        WHERE ts >= {cutoff}
        """
    ).fetchone()
    stats = dict(row) if row else {}
    rows = conn.execute(
        f"""
        SELECT model, COUNT(*) as calls, AVG(duration_ms) as avg_ms, AVG(tokens) as avg_tokens
        FROM request_records
        WHERE ts >= {cutoff}
        GROUP BY model
        ORDER BY calls DESC
        LIMIT 20
        """
    ).fetchall()
    stats["by_model"] = [dict(r) for r in rows]
    return stats


# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

def insert_log(entry: dict):
    text = entry.get("text", "")
    # Use level from entry if already computed (main.py does this), else derive it
    level = entry.get("level") or (
        "error" if ("error" in text.lower() or "fatal" in text.lower())
        else "warn" if "warn" in text.lower()
        else "info"
    )
    source = entry.get("source", "server")
    conn = get_conn()
    conn.execute(
        "INSERT INTO log_entries (ts, text, level, source) VALUES (?,?,?,?)",
        (entry.get("ts", datetime.now(timezone.utc).isoformat()), text, level, source),
    )
    conn.commit()


def get_log_history(hours: float = 24, level: Optional[str] = None,
                    source: Optional[str] = None, limit: int = 2000) -> list[dict]:
    conn = get_conn()
    cutoff = f"datetime('now', '-{hours} hours')"
    where = [f"ts >= {cutoff}"]
    params: list = []
    if level:
        where.append("level=?")
        params.append(level)
    if source:
        where.append("source=?")
        params.append(source)
    params.append(limit)
    rows = conn.execute(
        f"SELECT ts, text, level, source FROM log_entries WHERE {' AND '.join(where)} ORDER BY ts DESC LIMIT ?",
        params,
    ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

def get_setting(key: str) -> Optional[str]:
    row = get_conn().execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row else None


def set_setting(key: str, value: str):
    conn = get_conn()
    conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", (key, value))
    conn.commit()


# ---------------------------------------------------------------------------
# Sessions (auth tokens)
# ---------------------------------------------------------------------------

def create_session(token: str):
    conn = get_conn()
    conn.execute(
        "INSERT OR REPLACE INTO sessions (token, created_at) VALUES (?,?)",
        (token, datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()


def load_all_tokens() -> set[str]:
    conn = get_conn()
    conn.execute("DELETE FROM sessions WHERE created_at < datetime('now', '-30 days')")
    conn.commit()
    rows = conn.execute("SELECT token FROM sessions").fetchall()
    return {r["token"] for r in rows}


def delete_session(token: str):
    conn = get_conn()
    conn.execute("DELETE FROM sessions WHERE token=?", (token,))
    conn.commit()


def delete_all_sessions():
    conn = get_conn()
    conn.execute("DELETE FROM sessions")
    conn.commit()


# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------

def prune_old_data(keep_days: int = 7):
    conn = get_conn()
    cutoff = f"datetime('now', '-{keep_days} days')"
    conn.execute(f"DELETE FROM metrics_snapshots WHERE ts < {cutoff}")
    conn.execute(f"DELETE FROM request_records WHERE ts < {cutoff}")
    conn.execute(f"DELETE FROM log_entries WHERE ts < {cutoff}")
    conn.execute("VACUUM")
    conn.commit()
