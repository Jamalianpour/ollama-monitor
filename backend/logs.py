import asyncio
import re
from datetime import datetime, timezone
from pathlib import Path

import database as db
import log_parser
from state import log_lines, recent_requests
from websocket import broadcast

# Detects structured key=value format used by app.log
_STRUCT_RE = re.compile(r'^time=\S+ level=')
# Parses key=value and key="quoted value" pairs
_KV_RE = re.compile(r'([\w./:-]+)=(?:"((?:[^"\\]|\\.)*)"|(\S+))')


def _parse_kv(text: str) -> dict:
    result = {}
    for m in _KV_RE.finditer(text):
        k = m.group(1)
        result[k] = m.group(2) if m.group(2) is not None else m.group(3)
    return result


def _dur_ms(dur: str) -> float:
    """Convert app.log duration string (0s, 503.9µs, 1.234ms, 32.27s) to milliseconds."""
    if not dur:
        return 0
    if dur.endswith('µs'):
        try:
            return float(dur[:-2]) / 1000
        except ValueError:
            return 0
    if dur.endswith('ms'):
        try:
            return float(dur[:-2])
        except ValueError:
            return 0
    if dur.endswith('s'):
        try:
            return float(dur[:-1]) * 1000
        except ValueError:
            return 0
    return 0


def _format_app_line(pairs: dict) -> str:
    """Human-readable summary from a parsed app.log structured line."""
    msg = pairs.get('msg', '')
    if msg == 'site.serveHTTP':
        method   = pairs.get('http.method', '?')
        path     = pairs.get('http.path', '')
        status   = pairs.get('http.status', '?')
        duration = pairs.get('http.d', '')
        return f'{method} {path}  →  {status}  ({duration})'
    # Non-HTTP events: include selected context fields
    extras = []
    for k in ('target', 'port', 'app', 'version', 'file', 'error',
              'installer', 'interval', 'older', 'msg'):
        if k == 'msg':
            continue  # already in msg var
        if k in pairs and pairs[k]:
            v = pairs[k]
            if len(v) > 70:
                v = '…' + v[-67:]
            extras.append(f'{k}={v}')
    return f'{msg}  {" ".join(extras)}' if extras else msg


def _app_level(pairs: dict) -> str:
    return {'ERROR': 'error', 'FATAL': 'error', 'WARN': 'warn', 'DEBUG': 'debug'}.get(
        pairs.get('level', 'INFO').upper(), 'info')


def _is_noisy_app(pairs: dict) -> bool:
    """True for routine fast GET-200 requests that would flood the log panel."""
    if pairs.get('msg') != 'site.serveHTTP':
        return False
    if pairs.get('http.status', '200') != '200':
        return False   # keep non-200 (errors/redirects)
    if pairs.get('http.method', 'GET') != 'GET':
        return False   # keep POSTs (AI chat requests)
    return _dur_ms(pairs.get('http.d', '0s')) < 2000


def _level_from_line(text: str) -> str:
    lower = text.lower()
    for marker, level in [
        ('level=error', 'error'), ('level=warn', 'warn'),
        ('level=fatal', 'error'), ('level=debug', 'debug'),
    ]:
        if marker in lower:
            return level
    if ' | 4' in text or ' | 5' in text:
        return 'warn'
    if 'error' in lower or 'fatal' in lower:
        return 'error'
    if 'warn' in lower:
        return 'warn'
    return 'info'


def _should_persist_log(text: str, label: str) -> bool:
    lower = text.lower()
    return any(kw in lower for kw in (
        'error', 'warn', 'fatal', 'loaded', 'unloaded', 'starting',
        'listening', 'inference compute', 'skipping', 'discovering',
        'update', 'upgrade', 'shutdown',
    ))


def _make_entry(text: str, label: str, server_id: str = "default") -> dict:
    display_text = text
    level = _level_from_line(text)
    if label == 'app' and _STRUCT_RE.match(text):
        pairs = _parse_kv(text)
        display_text = _format_app_line(pairs)
        level = _app_level(pairs)
    return {
        'ts':        datetime.now(timezone.utc).isoformat(),
        'text':      display_text,
        'source':    label,
        'level':     level,
        'server_id': server_id,
    }


def _noisy(text: str, label: str) -> bool:
    if label != 'app' or not _STRUCT_RE.match(text):
        return False
    return _is_noisy_app(_parse_kv(text))


async def tail_log_file(log_path: Path, label: str, server_id: str = "default"):
    if not log_path.exists():
        entry = _make_entry(f'[monitor] Log not found: {log_path}', label, server_id)
        log_lines.append(entry)
        db.insert_log(entry)
        return

    # Seed last 100 non-noisy lines
    try:
        with open(log_path, 'r', errors='replace') as f:
            for line in f.readlines()[-100:]:
                text = line.rstrip()
                if not _noisy(text, label):
                    log_lines.append(_make_entry(text, label, server_id))
    except Exception as e:
        log_lines.append(_make_entry(f'[monitor] Seed error ({label}): {e}', label, server_id))

    # Live tail
    try:
        with open(log_path, 'r', errors='replace') as f:
            f.seek(0, 2)
            while True:
                line = f.readline()
                if line:
                    text = line.rstrip()
                    if not _noisy(text, label):
                        entry = _make_entry(text, label, server_id)
                        log_lines.append(entry)
                        if _should_persist_log(entry['text'], label):
                            db.insert_log(entry)
                        await broadcast({'type': 'log', 'server_id': server_id, 'data': entry})
                    if label == 'server':
                        log_parser.update_timing_buffer(text, server_id)
                        req = log_parser.parse_gin_request(text, server_id)
                        if req is not None:
                            recent_requests.append(req)
                            db.insert_request(req)
                            await broadcast({'type': 'request', 'server_id': server_id, 'data': req})
                else:
                    await asyncio.sleep(0.2)
    except Exception as e:
        entry = _make_entry(f'[monitor] Tail error ({label}): {e}', label, server_id)
        log_lines.append(entry)
        db.insert_log(entry)


def _journald_label(text: str) -> str:
    """Detect whether a raw journald message is an app (structured) or server (gin/llama) line."""
    return 'app' if _STRUCT_RE.match(text) else 'server'


async def tail_log_journald(server_id: str = "default"):
    # ── Phase 1: seed last 100 lines (no broadcast, no request parsing to avoid DB dups) ──
    try:
        seed_proc = await asyncio.create_subprocess_exec(
            'journalctl', '-u', 'ollama', '-n', '100', '--no-pager', '--output=cat',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        seed_out, _ = await seed_proc.communicate()
        for raw_line in seed_out.splitlines():
            text = raw_line.decode(errors='replace').strip()
            if not text:
                continue
            label = _journald_label(text)
            if not _noisy(text, label):
                log_lines.append(_make_entry(text, label, server_id))
    except Exception as e:
        log_lines.append(_make_entry(f'[monitor] journalctl seed error: {e}', 'server', server_id))

    # ── Phase 2: live follow from this moment onwards ──────────────────────────
    try:
        proc = await asyncio.create_subprocess_exec(
            'journalctl', '-u', 'ollama', '-f', '-n', '0', '--no-pager', '--output=cat',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        async for raw in proc.stdout:
            text = raw.decode(errors='replace').rstrip()
            if not text:
                continue
            label = _journald_label(text)
            if _noisy(text, label):
                continue
            entry = _make_entry(text, label, server_id)
            log_lines.append(entry)
            if _should_persist_log(entry['text'], label):
                db.insert_log(entry)
            await broadcast({'type': 'log', 'server_id': server_id, 'data': entry})
            if label == 'server':
                log_parser.update_timing_buffer(text, server_id)
                req = log_parser.parse_gin_request(text, server_id)
                if req is not None:
                    recent_requests.append(req)
                    db.insert_request(req)
                    await broadcast({'type': 'request', 'server_id': server_id, 'data': req})
    except Exception as e:
        entry = _make_entry(f'[monitor] journalctl error: {e}', 'server', server_id)
        log_lines.append(entry)
        db.insert_log(entry)
