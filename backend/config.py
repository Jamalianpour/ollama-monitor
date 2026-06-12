import os
import platform
from pathlib import Path

OLLAMA_BASE    = os.getenv("OLLAMA_HOST", "http://localhost:11434")
POLL_INTERVAL  = float(os.getenv("POLL_INTERVAL", "2"))
PRUNE_INTERVAL = 3600
LOG_KEEP_DAYS  = int(os.getenv("LOG_KEEP_DAYS", "7"))


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
