#!/usr/bin/env bash
# Vape Bot Setup — installs dependencies and configures config.py interactively.
# Run: bash bot_setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.py"

echo "================================="
echo "   ██╗   ██╗ █████╗ ██████╗ ███████╗"
echo "   ██║   ██║██╔══██╗██╔══██╗██╔════╝"
echo "   ██║   ██║███████║██████╔╝█████╗  "
echo "   ╚██╗ ██╔╝██╔══██║██╔═══╝ ██╔══╝  "
echo "    ╚████╔╝ ██║  ██║██║     ███████╗"
echo "     ╚═══╝  ╚═╝  ╚═╝╚═╝     ╚══════╝"
echo "   Powered by Vape Engine — Bot Setup"
echo "================================="
echo ""

###############################################################################
# 1. Python check
###############################################################################
if ! command -v python3 &>/dev/null; then
    echo "Python3 not found. Installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-pip
    elif command -v yum &>/dev/null; then
        sudo yum install -y -q python3 python3-pip
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q python3 python3-pip
    else
        echo "ERROR: Cannot install Python3 automatically. Install it manually and re-run."
        exit 1
    fi
fi

PY=$(command -v python3)
PIP=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || echo "")

if [[ -z "$PIP" ]]; then
    $PY -m ensurepip --upgrade 2>/dev/null || true
    PIP="$PY -m pip"
fi

echo "[1/3] Installing Python packages..."
$PIP install --quiet --upgrade --break-system-packages --ignore-installed discord.py aiohttp
echo "      discord.py, aiohttp — done."

###############################################################################
# 2. Interactive config
###############################################################################
echo ""
echo "[2/3] Bot configuration..."
echo ""

read -rp  "  Bot Token                        : " BOT_TOKEN
read -rp  "  Owner Discord ID                 : " OWNER_ID

echo "  Authorized user IDs (space-separated, leave blank to skip):"
read -rp  "  IDs                              : " RAW_IDS

read -rp  "  Connections per node    [50000]  : " CONNECTIONS
CONNECTIONS="${CONNECTIONS:-50000}"

read -rp  "  Duration (seconds)      [60]     : " DURATION
DURATION="${DURATION:-60}"

read -rp  "  CPU Threads per node    [0=auto] : " THREADS
THREADS="${THREADS:-0}"

read -rp  "  Cooldown extra (seconds)[5]      : " COOLDOWN_EXTRA
COOLDOWN_EXTRA="${COOLDOWN_EXTRA:-5}"

read -rp  "  Lownet mode             [n/y]    : " LOWNET_RAW
if [[ "${LOWNET_RAW,,}" == "y" ]]; then LOWNET="True"; else LOWNET="False"; fi

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

# Static authorized user IDs — runtime whitelist managed via \$vape whitelist add/remove
AUTHORIZED_USER_IDS = [
$(printf "%b" "$IDS_PY")]

# ─── Attack Defaults ──────────────────────────────────────────────────────────

CONNECTIONS = ${CONNECTIONS}     # concurrent connections per node
DURATION    = ${DURATION}         # attack duration in seconds
THREADS     = ${THREADS}          # CPU threads per node  (0 = all cores / auto)
LOWNET      = ${LOWNET}       # True = minimum bandwidth mode (~7x less TX)

# ─── Cooldown ─────────────────────────────────────────────────────────────────
# Total cooldown = DURATION + COOLDOWN_EXTRA seconds between attacks.

COOLDOWN_EXTRA = ${COOLDOWN_EXTRA}

# ─── Embed ────────────────────────────────────────────────────────────────────

EMBED_COLOR  = 0xFFFFFF
EMBED_FOOTER = "Developer: @Paxjest  •  Engine: @Xstairs"
PYEOF

echo "      config.py written."
echo ""
echo "================================="
echo "  Setup complete."
echo ""
echo "  Start the bot:"
echo "    python3 $SCRIPT_DIR/bot.py"
echo ""
echo "  Commands (in Discord):"
echo "    \$vape <host> <port>              — launch attack"
echo "    \$vape api add <name> <url> [bw]  — add node      (owner)"
echo "    \$vape api remove <name>          — remove node   (owner)"
echo "    \$vape api status                 — node health   (owner)"
echo "    \$vape whitelist add @user        — whitelist     (owner)"
echo "    \$vape whitelist remove @user     — unwhitelist   (owner)"
echo "================================="
