import json
import os
import platform
from pathlib import Path

POLL_INTERVAL  = float(os.getenv("POLL_INTERVAL", "2"))
PRUNE_INTERVAL = 3600
LOG_KEEP_DAYS  = int(os.getenv("LOG_KEEP_DAYS", "7"))


def _parse_servers() -> list[dict]:
    """Parse OLLAMA_SERVERS into a list of {id, name, url} dicts.

    Supported formats:
      JSON array: [{"id":"s1","name":"GPU Box","url":"http://192.168.1.10:11434"}]
      CSV urls:   http://host1:11434,http://host2:11434
    Falls back to OLLAMA_HOST / localhost:11434 when unset.
    """
    raw = os.getenv("OLLAMA_SERVERS", "").strip()
    if raw:
        if raw.startswith("["):
            try:
                servers = json.loads(raw)
                for i, s in enumerate(servers):
                    s.setdefault("id",   f"s{i+1}")
                    s.setdefault("name", f"Server {i+1}")
                if servers:
                    return servers
            except json.JSONDecodeError:
                pass
        urls = [u.strip() for u in raw.split(",") if u.strip()]
        if urls:
            return [{"id": f"s{i+1}", "name": f"Server {i+1}", "url": url}
                    for i, url in enumerate(urls)]
    url = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    return [{"id": "default", "name": "Default", "url": url}]


SERVERS: list[dict] = _parse_servers()
OLLAMA_BASE = SERVERS[0]["url"]   # backward compat


def default_log_paths() -> list[tuple[Path, str]]:
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

    if os.getenv("OLLAMA_APP_LOG"):
        found.append((Path(os.environ["OLLAMA_APP_LOG"]), "app"))
    if os.getenv("OLLAMA_SERVER_LOG"):
        found.append((Path(os.environ["OLLAMA_SERVER_LOG"]), "server"))
    if os.getenv("OLLAMA_LOG"):
        found.append((Path(os.environ["OLLAMA_LOG"]), "server"))

    return found


LOG_PATHS: list[tuple[Path, str]] = default_log_paths()
