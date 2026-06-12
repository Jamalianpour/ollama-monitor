"""
Parses Ollama server.log lines to extract structured request records.

Two log sources are correlated:
  GIN lines  — HTTP request/response (timestamp, status, duration, endpoint)
  slot lines — llama.cpp inference timing (tokens/s, prompt tokens, eval tokens)

The slot timing lines appear *during* inference and the GIN line fires when
the HTTP response is fully sent, so timing is buffered by task_id and the most
recently completed task is attached to each incoming GIN inference line.
"""

import re
from datetime import datetime, timezone
from typing import Optional

import state

# ── Inference endpoints worth tracking ────────────────────────────────────────
_INFERENCE_PATHS = frozenset({'/api/chat', '/api/generate', '/api/embeddings', '/api/embed'})

# ── Regex patterns ─────────────────────────────────────────────────────────────

# [GIN] 2026/06/12 - 22:48:16 | 200 |   36.3300089s |  127.0.0.1 | POST "/api/chat"
_GIN_RE = re.compile(
    r'\[GIN\]\s+\d{4}/\d{2}/\d{2} - (\d{2}:\d{2}:\d{2})\s+\|\s+'
    r'(\d+)\s+\|\s+(.+?)\s+\|\s+\S+\s+\|\s+(\w+)\s+"([^"]+)"'
)

# Duration: 36.3300089s  7.0633ms  506.6µs  0s
_DURATION_RE = re.compile(r'([\d.]+)(µs|ms|s)')

# slot print_timing: id  0 | task 419 | n_decoded = 100, tg = 121.87 t/s
_TG_RE = re.compile(
    r'slot\s+print_timing:.*?task\s+(\d+)\s*\|.*?n_decoded\s*=\s*(\d+).*?tg\s*=\s*([\d.]+)'
)
# slot print_timing: id  0 | task 419 | prompt eval time = 501.06 ms / 67 tokens ( ... 133.72 tokens per second)
_PROMPT_RE = re.compile(
    r'slot\s+print_timing:.*?task\s+(\d+).*?\|\s+prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second'
)
# slot print_timing: id  0 | task 419 |        eval time = 2609.54 ms / 326 tokens ( ... 124.93 tokens per second)
# Note: must NOT match the "prompt eval time" line — the \| before eval time handles this
_EVAL_RE = re.compile(
    r'slot\s+print_timing:.*?task\s+(\d+).*?\|\s+eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second'
)
# slot print_timing: id  0 | task 419 |       total time = 3110.60 ms / 393 tokens
_TOTAL_RE = re.compile(
    r'slot\s+print_timing:.*?task\s+(\d+).*?\|\s+total time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens'
)
# slot      release: id  0 | task 419 | stop processing: n_tokens = 406, truncated = 0
_RELEASE_RE = re.compile(
    r'slot\s+release:.*?task\s+(\d+).*?n_tokens\s*=\s*(\d+)'
)

# ── Internal timing buffer ─────────────────────────────────────────────────────

_buf: dict[int, dict] = {}   # task_id → accumulated timing fields
_done: list[int] = []        # task_ids whose timing is complete (total time seen), ordered by arrival


def _parse_duration_ms(s: str) -> Optional[float]:
    s = s.strip()
    if s == '0s':
        return 0.0
    m = _DURATION_RE.match(s)
    if not m:
        return None
    val, unit = float(m.group(1)), m.group(2)
    if unit == 'µs':
        return val / 1000.0
    if unit == 'ms':
        return val
    return val * 1000.0  # seconds → ms


def update_timing_buffer(text: str) -> None:
    """Update internal buffer from a single server.log line."""
    m = _TG_RE.search(text)
    if m:
        tid = int(m.group(1))
        _buf.setdefault(tid, {}).update(n_decoded=int(m.group(2)), tg_tps=float(m.group(3)))
        return

    m = _PROMPT_RE.search(text)
    if m:
        tid = int(m.group(1))
        _buf.setdefault(tid, {}).update(
            prompt_eval_ms=float(m.group(2)),
            prompt_tokens=int(m.group(3)),
            prompt_tps=float(m.group(4)),
        )
        return

    m = _EVAL_RE.search(text)
    if m:
        tid = int(m.group(1))
        _buf.setdefault(tid, {}).update(
            eval_ms=float(m.group(2)),
            eval_tokens=int(m.group(3)),
            eval_tps=float(m.group(4)),
        )
        return

    m = _TOTAL_RE.search(text)
    if m:
        tid = int(m.group(1))
        _buf.setdefault(tid, {}).update(
            total_ms=float(m.group(2)),
            total_tokens=int(m.group(3)),
        )
        if tid not in _done:
            _done.append(tid)
            if len(_done) > 20:
                _buf.pop(_done.pop(0), None)
        return

    m = _RELEASE_RE.search(text)
    if m:
        tid = int(m.group(1))
        if tid in _buf:
            _buf[tid]['n_tokens'] = int(m.group(2))


def _pop_latest_timing() -> dict:
    """Return and remove the most recently completed task's timing data."""
    if not _done:
        return {}
    tid = _done.pop()
    return _buf.pop(tid, {})


def _infer_model() -> str:
    """Best-effort model name from the current running-models state."""
    models = state.running_models
    if len(models) == 1:
        return models[0].get('name', 'unknown')
    return 'unknown'


def parse_gin_request(text: str) -> Optional[dict]:
    """
    Parse a GIN log line. If it represents a completed inference request,
    return a request record dict (ready for db.insert_request + broadcast).
    Returns None for any other line.
    """
    m = _GIN_RE.search(text)
    if not m:
        return None

    _time_str, status, duration_raw, method, path = m.groups()
    path = path.split('?')[0]
    if path not in _INFERENCE_PATHS:
        return None

    duration_ms = _parse_duration_ms(duration_raw)
    status_code = int(status)
    timing = _pop_latest_timing()

    tokens = (
        timing.pop('total_tokens', None)
        or timing.pop('n_tokens', None)
        or timing.pop('n_decoded', None)
    )

    return {
        "ts":          datetime.now(timezone.utc).isoformat(),
        "model":       _infer_model(),
        "duration_ms": int(duration_ms) if duration_ms is not None else None,
        "tokens":      tokens,
        "error":       status_code >= 400,
        "path":        path,
        "status":      status_code,
        **timing,  # tg_tps, eval_ms, eval_tokens, eval_tps, prompt_eval_ms, prompt_tokens, prompt_tps
    }
