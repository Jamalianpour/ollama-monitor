#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Ollama Monitor – Linux systemd service installer
# Usage:  sudo bash install-linux.sh [--user USER] [--install-dir DIR]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SERVICE_USER="${SERVICE_USER:-$(logname 2>/dev/null || echo ollama-monitor)}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ollama-monitor}"
DB_DIR="/var/lib/ollama-monitor"
ENV_DIR="/etc/ollama-monitor"
SERVICE_FILE="/etc/systemd/system/ollama-monitor.service"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --user)     SERVICE_USER="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "==> Installing Ollama Monitor"
echo "    Install dir : $INSTALL_DIR"
echo "    Service user: $SERVICE_USER"
echo "    DB dir      : $DB_DIR"

# ── Create system user if it doesn't exist ────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
  echo "==> Creating system user: $SERVICE_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# ── Copy source files ─────────────────────────────────────────────────────────
echo "==> Copying source to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$REPO_ROOT/backend/." "$INSTALL_DIR/backend/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ── Python venv + dependencies ────────────────────────────────────────────────
echo "==> Setting up Python venv"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/backend/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.venv"

# ── DB directory ──────────────────────────────────────────────────────────────
echo "==> Creating DB directory: $DB_DIR"
mkdir -p "$DB_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$DB_DIR"

# ── Env config directory ──────────────────────────────────────────────────────
mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_DIR/env" ]]; then
  cat > "$ENV_DIR/env" <<EOF
# Ollama Monitor environment overrides
# OLLAMA_HOST=http://localhost:11434
# OLLAMA_LOG=/var/log/ollama.log
MONITOR_DB=$DB_DIR/monitor.db
# POLL_INTERVAL=2
# LOG_KEEP_DAYS=7
EOF
  echo "==> Created $ENV_DIR/env  (edit to override settings)"
fi

# ── Systemd service file ──────────────────────────────────────────────────────
echo "==> Installing systemd service"
sed \
  -e "s|%i|$SERVICE_USER|g" \
  -e "s|/opt/ollama-monitor|$INSTALL_DIR|g" \
  "$REPO_ROOT/service/ollama-monitor.service" \
  > "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable ollama-monitor
systemctl restart ollama-monitor

echo ""
echo "✓ Ollama Monitor installed and started."
echo ""
echo "  Status:  systemctl status ollama-monitor"
echo "  Logs:    journalctl -u ollama-monitor -f"
echo "  Config:  $ENV_DIR/env"
echo "  DB:      $DB_DIR/monitor.db"
echo ""
