#!/usr/bin/env bash
# Vape Bot Setup — installs dependencies and configures config.py interactively.
# Run: bash bot_setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.py"

echo "==============================="
echo "  Vape Discord Bot — Setup"
echo "==============================="
echo ""

###############################################################################
# 1. Python check
###############################################################################
if ! command -v python3 &>/dev/null; then
    echo "Python3 not found. Installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-pip
    elif command -v yum &>/dev/null; then
        sudo yum install -y python3 python3-pip
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y python3 python3-pip
    else
        echo "Cannot install Python3 automatically. Install it manually and re-run."
        exit 1
    fi
fi

PY=$(command -v python3)
PIP=$(command -v pip3 || command -v pip || echo "")

if [[ -z "$PIP" ]]; then
    $PY -m ensurepip --upgrade 2>/dev/null || true
    PIP="$PY -m pip"
fi

echo "[1/3] Installing Python packages..."
$PIP install --quiet --upgrade --break-system-packages --ignore-installed discord.py aiohttp
echo "    discord.py, aiohttp installed."

###############################################################################
# 2. Interactive config
###############################################################################
echo ""
echo "[2/3] Configuring bot..."
echo ""

read -rp "  Bot Token     : " BOT_TOKEN
read -rp "  Owner ID      : " OWNER_ID

echo "  Authorized User IDs (up to 8, space-separated, leave blank to skip):"
read -rp "  IDs           : " RAW_IDS

read -rp "  Connections   [50000] : " CONNECTIONS
CONNECTIONS="${CONNECTIONS:-50000}"

read -rp "  Duration sec  [60]    : " DURATION
DURATION="${DURATION:-60}"

read -rp "  Cooldown extra sec [5]: " COOLDOWN_EXTRA
COOLDOWN_EXTRA="${COOLDOWN_EXTRA:-5}"

read -rp "  Lownet mode   [n/y]   : " LOWNET_RAW
if [[ "${LOWNET_RAW,,}" == "y" ]]; then LOWNET="True"; else LOWNET="False"; fi

read -rp "  API Key (shared with nodes): " API_KEY

# Build authorized IDs list
IDS_PY=""
if [[ -n "$RAW_IDS" ]]; then
    for id in $RAW_IDS; do
        IDS_PY+="    $id,\n"
    done
fi

###############################################################################
# 3. Write config.py
###############################################################################
echo ""
echo "[3/3] Writing config.py..."

cat > "$CONFIG" <<PYEOF
# ─── Vape Bot Configuration ───────────────────────────────────────────────────

BOT_TOKEN = "${BOT_TOKEN}"

OWNER_ID = ${OWNER_ID}

AUTHORIZED_USER_IDS = [
$(printf "%b" "$IDS_PY")]

# ─── Attack Defaults ──────────────────────────────────────────────────────────

CONNECTIONS = ${CONNECTIONS}
DURATION    = ${DURATION}
LOWNET      = ${LOWNET}

# ─── Cooldown ─────────────────────────────────────────────────────────────────

COOLDOWN_EXTRA = ${COOLDOWN_EXTRA}

# ─── API Authentication ────────────────────────────────────────────────────────

API_KEY = "${API_KEY}"

# ─── Embed ────────────────────────────────────────────────────────────────────

EMBED_COLOR  = 0x8B0000
EMBED_FOOTER = "Developer: @Paxjest"
PYEOF

echo "    config.py written."
echo ""
echo "==============================="
echo "  Setup complete."
echo ""
echo "  Start the bot:"
echo "    python3 $SCRIPT_DIR/bot.py"
echo ""
echo "  Add a node (in Discord, as owner):"
echo '    $owxaddr api add <name> <http://IP:8080> <bandwidth>'
echo "==============================="
