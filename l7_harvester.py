#!/usr/bin/env python3
"""
Vape Ultra v1.2 — Layer 7 Session Harvester
Developer: @Paxjest  Engine: @Xstairs

Opens a real Chrome window inside the virtual display (Xvfb).
Connect via noVNC, navigate to the target, and solve any Cloudflare
challenge. The script captures cf_clearance + Chrome headers + UA,
writes session.json, and auto-refreshes every 25 minutes.

Usage:
    python3 l7_harvester.py https://target.com
    python3 l7_harvester.py https://target.com --session /path/session.json
    python3 l7_harvester.py https://target.com --port 8443 --path /api
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from urllib.parse import urlparse

# ─── Dependency bootstrap ─────────────────────────────────────────────────────

def _pip(*pkgs):
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--break-system-packages", "--ignore-installed", *pkgs],
        check=False
    )

try:
    from playwright.sync_api import sync_playwright  # noqa: F401
except ImportError:
    print("[harvester] Installing playwright...", flush=True)
    _pip("playwright")
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError:
        print("[harvester] ERROR: playwright install failed.", flush=True)
        print(f"  Run manually: {sys.executable} -m pip install playwright")
        sys.exit(1)

# Ensure Chromium binaries exist
_r = subprocess.run(
    [sys.executable, "-m", "playwright", "install", "chromium"],
    capture_output=True
)
if _r.returncode != 0:
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chrome"],
        capture_output=True
    )

from playwright.sync_api import sync_playwright, BrowserContext  # noqa: E402

# ─── Constants ────────────────────────────────────────────────────────────────

CF_CLEARANCE = "cf_clearance"
CF_BM        = "__cf_bm"
CF_LB        = "__cflb"

REFRESH_INTERVAL = 25 * 60   # seconds between auto-refresh
POLL_INTERVAL    = 1.0        # seconds between cookie polls
MAX_WAIT         = 8 * 60     # max seconds to wait for challenge solve (8 min)
POLL_LOG_EVERY   = 10         # print "still waiting" every N seconds


# ─── Helpers ──────────────────────────────────────────────────────────────────

def ts() -> str:
    return datetime.now().strftime("%H:%M:%S")

def log(msg: str):
    print(f"[{ts()}] {msg}", flush=True)


def _base_domain(domain: str) -> str:
    """
    Normalise to bare domain for matching.
    '.www.example.com' -> 'example.com'
    'www.example.com'  -> 'example.com'
    'example.com'      -> 'example.com'
    """
    d = domain.lstrip(".").lower()
    if d.startswith("www."):
        d = d[4:]
    return d


def get_cookies(context: BrowserContext, host: str) -> dict:
    """
    Return cookies relevant to the target host.

    Fixes the original bug: Cloudflare sets cf_clearance on '.example.com'
    (leading dot, no www).  A strict substring check of 'www.example.com'
    inside '.example.com' returns False and the cookie is never captured.

    Strategy (three-pass, most-specific first):
      1. Exact domain match (cookie domain == host)
      2. Base-domain match after stripping www. and leading dots from both
      3. Global scan — grab cf_clearance regardless of domain (last resort)
    """
    all_cookies = context.cookies()
    result: dict = {}
    base_host = _base_domain(host)

    # Pass 1 + 2
    for c in all_cookies:
        c_raw  = c.get("domain", "")
        c_norm = c_raw.lstrip(".").lower()
        c_base = _base_domain(c_raw)
        name   = c["name"]
        value  = c["value"]

        exact_match = (c_norm == host.lower())
        base_match  = (c_base == base_host) or (base_host in c_base) or (c_base in base_host)

        if exact_match or base_match:
            result[name] = value

    # Pass 3 — always grab CF tokens wherever they appear
    for c in all_cookies:
        if c["name"] in (CF_CLEARANCE, CF_BM, CF_LB) and c["name"] not in result:
            result[c["name"]] = c["value"]
            log(f"[domain-fallback] captured {c['name']} from {c.get('domain','?')}")

    return result


def build_cookie_header(cookies: dict) -> str:
    """Build Cookie: header value, CF tokens first."""
    parts = []
    for name in (CF_CLEARANCE, CF_BM, CF_LB):
        if name in cookies:
            parts.append(f"{name}={cookies[name]}")
    for k, v in cookies.items():
        if k not in (CF_CLEARANCE, CF_BM, CF_LB):
            parts.append(f"{k}={v}")
    return "; ".join(parts)


def write_session(path: str, data: dict):
    """Write session.json atomically so vape_ultra never reads a partial file."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    log(f"session.json written → {path}")


# ─── Core harvest ─────────────────────────────────────────────────────────────

def harvest(url: str, session_file: str,
            override_port: int = None, override_path: str = None):

    parsed       = urlparse(url)
    scheme       = parsed.scheme or "https"
    host         = (parsed.hostname or parsed.path or "").lower()
    path         = override_path or parsed.path or "/"
    if not path or path == host:
        path = "/"
    default_port = 443 if scheme == "https" else 80
    port         = override_port or parsed.port or default_port

    full_url = f"{scheme}://{host}"
    if port not in (80, 443):
        full_url += f":{port}"
    full_url += path

    log("=" * 60)
    log(f"Target  : {full_url}")
    log(f"Session : {session_file}")
    log("=" * 60)

    with sync_playwright() as pw:

        # ── Launch Chrome ──────────────────────────────────────────────────────
        CHROME_ARGS = [
            "--disable-blink-features=AutomationControlled",
            "--no-sandbox",
            "--disable-infobars",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-popup-blocking",
            f"--window-size=1280,800",
            "--window-position=0,0",
            "--start-maximized",
        ]

        browser = None
        for channel, extra in [("chrome", []), (None, [])]:
            try:
                kw = dict(headless=False, args=CHROME_ARGS)
                if channel:
                    kw["channel"] = channel
                browser = pw.chromium.launch(**kw)
                log(f"Browser: {'system Chrome' if channel else 'Playwright Chromium'}")
                break
            except Exception as exc:
                log(f"Launch attempt ({channel}) failed: {exc}")

        if browser is None:
            log("ERROR: Could not launch any browser. Check Playwright install.")
            return None

        context = browser.new_context(
            viewport={"width": 1280, "height": 800},
            locale="en-US",
            timezone_id="America/New_York",
            ignore_https_errors=True,
        )

        # ── Capture request headers (UA + all request headers) ────────────────
        captured_ua      = ""
        captured_headers: dict = {}
        headers_locked   = False

        def on_request(req):
            nonlocal captured_ua, captured_headers, headers_locked
            if headers_locked:
                return
            if host not in req.url:
                return
            hdrs = dict(req.headers)
            ua   = hdrs.get("user-agent", hdrs.get("User-Agent", ""))
            if ua and not captured_ua:
                captured_ua      = ua
                captured_headers = hdrs
                log(f"UA captured: {ua[:72]}...")

        page = context.new_page()
        page.on("request", on_request)

        # ── Navigate ──────────────────────────────────────────────────────────
        log("Navigating to target...")
        try:
            page.goto(full_url, timeout=45000, wait_until="domcontentloaded")
        except Exception as exc:
            log(f"Navigation note (non-fatal): {exc}")

        # ── Poll for cf_clearance ─────────────────────────────────────────────
        log(f"Waiting up to {MAX_WAIT // 60} min for cf_clearance cookie...")
        log(">>> Connect via noVNC and solve the Cloudflare challenge <<<")

        deadline         = time.time() + MAX_WAIT
        cf_clearance_val = ""
        last_log_t       = time.time()
        poll_count       = 0

        while time.time() < deadline:
            try:
                cookies          = get_cookies(context, host)
                cf_clearance_val = cookies.get(CF_CLEARANCE, "")
            except Exception:
                cookies = {}

            if cf_clearance_val:
                log("cf_clearance CAPTURED!")
                break

            poll_count += 1
            now = time.time()
            if now - last_log_t >= POLL_LOG_EVERY:
                remaining = int(deadline - now)
                log(f"Still waiting... {remaining}s left. "
                    f"Total cookies so far: {len(cookies)}"
                    + (f"  keys={list(cookies.keys())}" if cookies else ""))
                last_log_t = now

            time.sleep(POLL_INTERVAL)

        if not cf_clearance_val:
            # Final attempt — dump all cookies to help debug
            try:
                all_c = context.cookies()
                log(f"Timed out. All cookies in context ({len(all_c)}):")
                for c in all_c:
                    log(f"  [{c.get('domain','')}] {c['name']} = {c['value'][:30]}...")
            except Exception:
                pass
            log("ERROR: cf_clearance not found. Did you solve the challenge?")
            browser.close()
            return None

        # ── Collect all CF cookies (small grace for __cf_bm) ─────────────────
        time.sleep(2.0)
        headers_locked = True  # stop UA capture now

        cookies    = get_cookies(context, host)
        cookie_hdr = build_cookie_header(cookies)
        cf_bm_val  = cookies.get(CF_BM, "")
        cf_lb_val  = cookies.get(CF_LB, "")

        # Fallback UA from JS if request listener didn't fire
        if not captured_ua:
            try:
                captured_ua = page.evaluate("() => navigator.userAgent")
                log(f"UA from JS: {captured_ua[:72]}...")
            except Exception:
                captured_ua = (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/125.0.0.0 Safari/537.36"
                )
                log("UA fallback to hardcoded Chrome 125 string.")

        valid_until = int(time.time()) + 30 * 60

        session = {
            "host":          host,
            "path":          path,
            "scheme":        scheme,
            "port":          port,
            "user_agent":    captured_ua,
            "cf_clearance":  cf_clearance_val,
            "cf_bm":         cf_bm_val,
            "cf_lb":         cf_lb_val,
            "cookie_header": cookie_hdr,
            "valid_until":   valid_until,
            "captured_at":   int(time.time()),
        }

        write_session(session_file, session)
        log(f"Session valid for ~30 min. Auto-refresh every "
            f"{REFRESH_INTERVAL // 60} min.")
        log("vape_ultra will hot-reload session.json every 30s automatically.")

        # ── Auto-refresh loop ─────────────────────────────────────────────────
        next_refresh = time.time() + REFRESH_INTERVAL

        while True:
            now       = time.time()
            remaining = int(next_refresh - now)

            if remaining <= 0:
                log("Auto-refreshing session...")
                try:
                    page.goto(full_url, timeout=45000, wait_until="domcontentloaded")
                    time.sleep(3)
                    cookies    = get_cookies(context, host)
                    cookie_hdr = build_cookie_header(cookies)

                    new_clr = cookies.get(CF_CLEARANCE, cf_clearance_val)
                    if new_clr and new_clr != cf_clearance_val:
                        log("New cf_clearance obtained silently.")
                        cf_clearance_val = new_clr

                    session.update({
                        "cf_clearance":  cookies.get(CF_CLEARANCE, cf_clearance_val),
                        "cf_bm":         cookies.get(CF_BM, ""),
                        "cf_lb":         cookies.get(CF_LB, ""),
                        "cookie_header": cookie_hdr,
                        "valid_until":   int(time.time()) + 30 * 60,
                        "captured_at":   int(time.time()),
                    })
                    write_session(session_file, session)
                    next_refresh = time.time() + REFRESH_INTERVAL

                except Exception as exc:
                    log(f"Refresh error: {exc} — retry in 60 s")
                    next_refresh = time.time() + 60

            else:
                # Print countdown every 60 s
                if remaining % 60 == 0 and remaining != REFRESH_INTERVAL:
                    log(f"Next session refresh in {remaining // 60}m {remaining % 60}s")
                time.sleep(1)


# ─── Entry point ──────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Vape Ultra v1.2 — L7 CF Session Harvester"
    )
    ap.add_argument("url",        help="Target URL, e.g. https://target.com")
    ap.add_argument("--session",  default="session.json",
                    help="Output session file path (default: session.json)")
    ap.add_argument("--port",     type=int, default=None,
                    help="Override port (default: 443/80 from scheme)")
    ap.add_argument("--path",     default=None,
                    help="Override URL path (default: /)")
    args = ap.parse_args()

    url = args.url
    if not url.startswith("http"):
        url = "https://" + url

    sfile = args.session
    if not os.path.isabs(sfile):
        sfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), sfile)

    try:
        harvest(url, sfile, override_port=args.port, override_path=args.path)
    except KeyboardInterrupt:
        log("Stopped by user (Ctrl+C).")
        sys.exit(0)
    except Exception as exc:
        log(f"Fatal error: {exc}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
