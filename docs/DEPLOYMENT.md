# Ollama Monitor — Deployment Guide

## Architecture

Ollama Monitor uses a **distributed** architecture:

- One **backend** deployed on each Ollama server machine
- One **frontend** (Flutter web) deployed anywhere and opened in the browser
- The frontend connects to all backends simultaneously over WebSocket

```
[Server 1: 192.168.1.10]  [Server 2: 192.168.1.11]  [Server 3: 192.168.1.12]
  ollama    :11434           ollama    :11434           ollama    :11434
  backend   :12434           backend   :12434           backend   :12434
        \                         |                         /
         \________________________|________________________/
                                  |
                         [Dashboard: 192.168.1.20]
                           nginx + Flutter web :80
                         (open this in the browser)
```

The backend connects to the **local** Ollama instance on each machine (`localhost:11434`).
The frontend is just a static web app — it can be hosted on any web server, or even opened from a local build.

---

## Step 1 — Deploy the Backend (repeat for each Ollama server)

### 1.1 Copy the backend to the server

```bash
scp -r backend/ user@192.168.1.10:/opt/ollama-monitor/
ssh user@192.168.1.10
cd /opt/ollama-monitor/backend
```

### 1.2 Find your Ollama log location

| OS | Log location |
|---|---|
| Linux — systemd install | journald (no files needed, backend reads it automatically) |
| Linux — manual install | `~/.ollama/logs/` or `/var/log/ollama/` |
| macOS | `~/.ollama/logs/` |
| Windows | `C:\Users\<YourUser>\AppData\Local\Ollama\` |

### 1.3 Configure environment variables

Create a `.env` file next to `docker-compose.yml`:

```bash
# Linux with log files
OLLAMA_HOST=http://localhost:11434
OLLAMA_SERVER_LOG=/ollama_logs/server.log
OLLAMA_APP_LOG=/ollama_logs/app.log
```

If Ollama runs under **systemd on Linux**, leave `OLLAMA_SERVER_LOG` and `OLLAMA_APP_LOG`
empty — the backend reads journald automatically without any log file mounts.

### 1.4 Mount the log directory

Edit `docker-compose.yml` and uncomment the log volume under the `backend` service:

```yaml
volumes:
  - db_data:/data
  - /var/log/ollama:/ollama_logs:ro   # Linux example — adjust path to match your setup
```

Common paths to use on the left side of the mount:

| OS | Host path |
|---|---|
| Linux | `/var/log/ollama` or `/home/<user>/.ollama/logs` |
| macOS (Docker Desktop) | `/Users/<user>/.ollama/logs` |
| Windows (Docker Desktop) | `C:\Users\<user>\AppData\Local\Ollama` |

### 1.5 Start the backend

```bash
docker compose up -d backend
```

Verify it is running:

```bash
curl http://localhost:12434/api/auth/status
# Expected: {"password_set": false}
```

**Repeat steps 1.1 – 1.5 for every Ollama server.**

---

## Step 2 — Deploy the Frontend (once)

The frontend is a Flutter web app compiled to static HTML/JS/WASM. It can be hosted anywhere.

### Option A — Docker (simplest, uses the existing docker-compose.yml)

Run this on the machine that will serve the dashboard:

```bash
# Requires the full repository (backend/ + ollama_monitor_app/)
docker compose up -d frontend
```

The dashboard is now available at `http://<dashboard-server>` (port 80).

### Option B — Build locally, serve static files

Use this if you do not want Docker on the dashboard server, or want to host on a CDN / GitHub Pages / Netlify.

```bash
# On your development machine
cd ollama_monitor_app
flutter build web --release

# The output is in build/web/ — copy it to any web server
rsync -av build/web/ user@192.168.1.20:/var/www/html/

# Or serve it locally for testing
cd build/web && python3 -m http.server 8080
```

---

## Step 3 — First-Time Setup in the Browser

1. Open the dashboard URL (e.g. `http://192.168.1.20`)
2. The connection field defaults to `http://localhost:12434` — change it to your **first** server:
   ```
   http://192.168.1.10:12434
   ```
3. Click **Connect**
4. The app shows "Set a password" — enter a password for Server 1 and click **Set Password**
5. You are now on the dashboard monitoring Server 1

### Add additional servers

6. Open **Account menu (top-right) → Manage Servers → Add Server**
7. Fill in:
   - **Name**: `GPU Server 2`
   - **URL**: `http://192.168.1.11:12434`
   - **Password**: *(same password you set on Server 1)*
8. Click **Connect** — the server is added and monitored immediately
9. Repeat for each additional server

A dropdown appears in the top bar to switch between servers once more than one is configured.

> **Note:** All backends must share the same password. When you log in, the frontend
> authenticates against all configured backends using the same credentials.

---

## Firewall Rules

| Machine | Port | Direction | Purpose |
|---|---|---|---|
| Each Ollama server | TCP 12434 | inbound | Browser → backend API + WebSocket |
| Dashboard server | TCP 80 (or 443) | inbound | Browser → Flutter web app |

---

## HTTPS / TLS (Recommended for Production)

The backend serves plain HTTP by default. If you want HTTPS (required when the frontend
itself is served over HTTPS), place nginx in front of each backend as a TLS-terminating
reverse proxy.

### nginx config for each backend server

```nginx
# /etc/nginx/sites-available/ollama-monitor
server {
    listen 443 ssl;
    server_name server1.yourdomain.com;

    ssl_certificate     /etc/ssl/certs/server1.crt;
    ssl_certificate_key /etc/ssl/private/server1.key;

    location / {
        proxy_pass http://localhost:12434;
        proxy_http_version 1.1;

        # Required for WebSocket upgrade
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       $host;

        proxy_read_timeout 3600s;
    }
}
```

After adding TLS, use `https://` URLs when adding servers in the app — the frontend
automatically uses `wss://` (secure WebSocket) when the URL starts with `https://`.

### Self-signed certificates (internal network)

For a private LAN with no public domain, you can generate a self-signed certificate:

```bash
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout server1.key -out server1.crt \
  -subj "/CN=192.168.1.10"
```

You will need to accept the certificate in the browser on first visit, or install a
local CA and trust it on all client machines.

---

## Updating

### Update the backend (on each Ollama server)

```bash
cd /opt/ollama-monitor/backend
git pull          # or re-copy the backend/ directory
docker compose build backend
docker compose up -d backend
```

### Update the frontend

**Docker:**
```bash
docker compose build frontend
docker compose up -d frontend
```

**Static build:**
```bash
cd ollama_monitor_app
flutter pub get
flutter build web --release
rsync -av build/web/ user@192.168.1.20:/var/www/html/
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| "Cannot reach backend" on login | Backend container is running? `docker compose ps` |
| WebSocket keeps reconnecting | Port 12434 open in firewall? `curl http://<server>:12434/api/auth/status` |
| No logs visible | Log volume mounted correctly? `OLLAMA_SERVER_LOG` / `OLLAMA_APP_LOG` set? |
| "Add Server" fails with wrong password | All backends must use the same password |
| Blank page after deploy | nginx `try_files` config correct? Check [nginx.conf](../ollama_monitor_app/nginx.conf) |
| GPU not showing | `nvidia-smi` or `rocm-smi` available inside the container? Add GPU pass-through to docker-compose |

### GPU pass-through (NVIDIA)

To expose GPU metrics, add this to the `backend` service in `docker-compose.yml`:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```
