#!/usr/bin/env bash
# Ollama Monitor – Linux uninstaller
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/ollama-monitor}"
SERVICE_USER="${SERVICE_USER:-ollama-monitor}"

echo "==> Stopping and disabling service"
systemctl stop ollama-monitor  2>/dev/null || true
systemctl disable ollama-monitor 2>/dev/null || true
rm -f /etc/systemd/system/ollama-monitor.service
systemctl daemon-reload

echo "==> Removing files"
rm -rf "$INSTALL_DIR"
rm -rf /etc/ollama-monitor

read -rp "Delete database at /var/lib/ollama-monitor? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  rm -rf /var/lib/ollama-monitor
  echo "    Database deleted."
fi

read -rp "Delete system user '$SERVICE_USER'? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  userdel "$SERVICE_USER" 2>/dev/null || true
fi

echo "✓ Ollama Monitor uninstalled."
