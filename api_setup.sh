#!/usr/bin/env bash
# Vape Node API Setup — installs deps, compiles vape binary, starts api.py.
# Run as root on each node: sudo bash api_setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAPE_BIN="$SCRIPT_DIR/vape"
API_FILE="$SCRIPT_DIR/api.py"
SERVICE_FILE="/etc/systemd/system/vape-api.service"

echo "==============================="
echo "  Vape Node API — Setup"
echo "==============================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash api_setup.sh"
    exit 1
fi

###############################################################################
# 1. Packages
###############################################################################
echo "[1/3] Installing packages..."

if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential g++ python3 python3-pip net-tools 2>/dev/null || true
elif command -v yum &>/dev/null; then
    yum install -y -q gcc-c++ python3 python3-pip net-tools 2>/dev/null || true
elif command -v dnf &>/dev/null; then
    dnf install -y -q gcc-c++ python3 python3-pip net-tools 2>/dev/null || true
fi

python3 -m pip install --quiet --upgrade --break-system-packages --ignore-installed flask
echo "    Packages done."

###############################################################################
# 2. Compile vape binary
###############################################################################
echo "[2/3] Compiling vape binary..."

if [[ -f "$SCRIPT_DIR/Vape-1.1.cpp" ]]; then
    VAPE_SRC="$SCRIPT_DIR/Vape-1.1.cpp"
    VAPE_VER="Vape-1.1"
elif [[ -f "$SCRIPT_DIR/Vape-1.0.cpp" ]]; then
    VAPE_SRC="$SCRIPT_DIR/Vape-1.0.cpp"
    VAPE_VER="Vape-1.0"
else
    echo "ERROR: No Vape-1.0.cpp or Vape-1.1.cpp found in $SCRIPT_DIR"
    echo "       Copy the Vape source files to this directory and re-run."
    exit 1
fi

g++ -O3 -march=native -mtune=native \
    -funroll-loops -fno-plt          \
    -ffast-math -fomit-frame-pointer \
    -std=c++17                       \
    -o "$VAPE_BIN"                   \
    "$VAPE_SRC"                      \
    -lpthread

strip "$VAPE_BIN"
echo "    Compiled $VAPE_VER → $VAPE_BIN"

###############################################################################
# 3. Systemd service
###############################################################################
echo "[3/3] Installing systemd service..."

cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Vape Node API
After=network.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=python3 $API_FILE
Environment="VAPE_API_PORT=8080"
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable vape-api
systemctl restart vape-api

sleep 1
STATUS=$(systemctl is-active vape-api 2>/dev/null || echo "failed")

echo ""
echo "==============================="
echo "  Node API Setup Complete"
echo "  Binary : $VAPE_BIN ($VAPE_VER)"
echo "  API    : http://$(hostname -I | awk '{print $1}'):8080"
echo "  Status : $STATUS"
echo ""
echo "  Check logs:  journalctl -u vape-api -f"
echo "  Stop:        systemctl stop vape-api"
echo "==============================="
