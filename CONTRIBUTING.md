# Contributing to Ollama Monitor

Thank you for considering contributing! This document covers how to get set up, what we're looking for, and how to submit changes.

---

## Project layout

```
ollama-monitor/
├── backend/                    Python FastAPI backend
│   ├── main.py                 Entry point — mounts routers, starts background tasks
│   ├── poller.py               Periodic Ollama API + system metric polling
│   ├── logs.py                 Log file / journald tailer and parser
│   ├── log_parser.py           GIN request and llama.cpp slot-timing parser
│   ├── database.py             SQLite persistence (metrics, requests, logs)
│   ├── config.py               Environment variable loading
│   ├── state.py                Shared in-memory deques
│   ├── auth.py                 Bearer-token dependency for FastAPI routes
│   ├── metrics.py              CPU / RAM / GPU snapshot via psutil / pynvml
│   ├── ollama.py               Async Ollama API client
│   ├── websocket.py            WebSocket broadcast helper
│   ├── routers/
│   │   ├── auth.py             /api/auth/* endpoints (login, setup, rate limiter)
│   │   ├── monitor.py          /api/health, /api/system, /api/ps, /api/logs, …
│   │   ├── history.py          /api/history/metrics, /api/history/requests
│   │   └── ws.py               /ws WebSocket endpoint
│   ├── requirements.txt
│   └── Dockerfile
├── ollama_monitor_app/         Flutter web dashboard
│   ├── lib/
│   │   ├── main.dart           App entry point, Provider wiring
│   │   ├── models/
│   │   │   ├── backend_entry.dart   BackendEntry model + SharedPreferences storage
│   │   │   └── monitor_state.dart   Data classes (MonitorSnapshot, LogLine, …)
│   │   ├── services/
│   │   │   ├── auth_service.dart    Multi-backend authentication
│   │   │   └── monitor_service.dart Multi-backend WebSocket connections
│   │   ├── screens/
│   │   │   ├── auth_screen.dart     Login / first-run password setup
│   │   │   └── dashboard.dart       Main dashboard (responsive, server selector)
│   │   └── widgets/
│   │       ├── gauge_card.dart
│   │       ├── gpu_card.dart
│   │       ├── history_chart.dart
│   │       ├── log_viewer.dart
│   │       ├── request_table.dart
│   │       ├── running_models_card.dart
│   │       └── stats_card.dart
│   ├── nginx.conf              nginx config for the Docker image
│   └── Dockerfile
├── service/                    OS service installers
│   ├── ollama-monitor.service  systemd unit (Linux)
│   ├── install-linux.sh
│   ├── uninstall-linux.sh
│   ├── install-windows.ps1
│   └── uninstall-windows.ps1
├── docs/
│   ├── DEPLOYMENT.md           Detailed multi-server deployment reference
│   ├── om_logo.png
│   └── sc_*.png                UI screenshots
├── docker-compose.yml
├── README.md
└── CONTRIBUTING.md
```

---

## Development setup

### Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python main.py
```

The server starts at `http://localhost:12434`.

Key environment variables for local development (create a `.env` or export in your shell):

```bash
OLLAMA_HOST=http://localhost:11434
# Optional: point to your Ollama log files
OLLAMA_SERVER_LOG=/path/to/server.log
OLLAMA_APP_LOG=/path/to/app.log
```

If neither log variable is set on Linux, the backend falls back to reading `journald` automatically.

### Frontend

```bash
cd ollama_monitor_app
flutter pub get
flutter run -d chrome
```

On first run the app shows a login screen. Point it at `http://localhost:12434` and set a password to get into the dashboard.

---

## Architecture notes

- **Multi-backend**: `AuthService` holds a `List<BackendEntry>` (persisted in `SharedPreferences`). `MonitorService` maintains one WebSocket connection per backend, all running concurrently. All incoming messages are tagged with the backend's id before being stored.
- **Single backend per Ollama machine**: each backend instance monitors only its local Ollama (`localhost:11434`). The frontend merges data from all backends.
- **Log parsing**: `logs.py` tails log files or journald (using `--output=cat` to strip the journald prefix). GIN request lines are forwarded to `log_parser.py` which correlates llama.cpp slot-timing lines to build full request records.
- **Rate limiting**: `/api/auth/login` tracks failures per source IP in a 60-second sliding window; 10 failures triggers a `429`.

---

## Branching model

| Branch | Purpose |
|---|---|
| `main` | Stable, released code |
| `dev` | Integration branch — PRs target here |
| `feat/<name>` | New features |
| `fix/<name>` | Bug fixes |

---

## Before submitting a PR

1. Run `dart analyze` and fix all warnings in `ollama_monitor_app/`:
   ```bash
   cd ollama_monitor_app && dart analyze lib
   ```
2. Run a quick syntax check on the backend:
   ```bash
   python -m py_compile backend/*.py backend/routers/*.py
   ```
3. Test on at least one of Linux / Windows / macOS.
4. Keep PRs focused — one feature or fix per PR.
5. Update `README.md` if you add config options or new endpoints.
6. Update `docs/DEPLOYMENT.md` if deployment steps change.

---

## Good first issues

- Add dark / light theme toggle to the Flutter dashboard
- Add a Prometheus `/metrics` endpoint to the backend
- Show model parameter count in the Running Models card
- Add webhook / email alerting when GPU or RAM exceeds a threshold
- Windows: test and document ROCm GPU detection
- Add per-backend connection status indicator to the server selector dropdown

---

## Code style

- **Python** — PEP 8, max line length 100. Type hints on all public functions.
- **Dart / Flutter** — official [Dart style guide](https://dart.dev/guides/language/effective-dart/style). Run `dart format` before committing.

---

## Reporting bugs

Open a GitHub Issue with:

- OS and version
- Ollama version (`ollama --version`)
- Steps to reproduce
- Expected vs actual behaviour
- Relevant log output:
  - **Backend**: `journalctl -u ollama-monitor -n 50` (Linux service) or `C:\OllamaMonitor\logs\` (Windows)
  - **Docker**: `docker compose logs backend`
  - **Browser**: Console output from DevTools

---

## License

By contributing you agree that your contributions will be licensed under the MIT License.
