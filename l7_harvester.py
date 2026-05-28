#!/usr/bin/env python3
"""
Vape Ultra v1.2 — Layer 7 Session Harvester
Developer: @Paxjest

Opens a real Chrome window. You navigate to the target and solve any
Cloudflare challenge manually. The script captures the cf_clearance cookie
and Chrome request headers, writes session.json, and auto-refreshes every
25 minutes to keep the token alive.

Usage:
    python3 l7_harvester.py https://target.com [--session session.json]
    python3 l7_harvester.py https://target.com --port 8443 --path /api
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from urllib.parse import urlparse

# ─── Dependency check ─────────────────────────────────────────────────────────

def ensure_deps():
    try:
        import playwright  # noqa: F401
    except ImportError:
        print("[harvester] Installing playwright...")
        os.system(
            f"{sys.executable} -m pip install --quiet "
            "--break-system-packages --ignore-installed playwright"
        )
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError:
        print("[harvester] ERROR: playwright install failed. Run manually:")
        print(f"  {sys.executable} -m pip install playwright")
        sys.exit(1)

    # Install browser binaries if needed
    import subprocess
    r = subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        capture_output=True
    )
    if r.returncode != 0:
        # Try installing chrome channel instead
        subprocess.run(
            [sys.executable, "-m", "playwright", "install", "chrome"],
            capture_output=True
        )

ensure_deps()

from playwright.sync_api import sync_playwright, Page, BrowserContext  # noqa: E402


# ─── Config ───────────────────────────────────────────────────────────────────

CF_CLEARANCE_COOKIE = "cf_clearance"
CF_BM_COOKIE        = "__cf_bm"
CF_LB_COOKIE        = "__cflb"
REFRESH_INTERVAL    = 25 * 60      # seconds between auto-refresh attempts
POLL_INTERVAL       = 1.0          # seconds between cookie polls
MAX_WAIT            = 5 * 60       # max seconds to wait for challenge solve


# ─── Helpers ──────────────────────────────────────────────────────────────────

def ts() -> str:
    return datetime.now().strftime("%H:%M:%S")

def log(msg: str):
    print(f"[{ts()}] {msg}", flush=True)


def get_cookies(context: BrowserContext, domain: str) -> dict:
    """Return cookies for the target domain as a name→value dict."""
    all_cookies = context.cookies()
    result = {}
    for c in all_cookies:
        if domain in c.get("domain", ""):
            result[c["name"]] = c["value"]
    return result


def build_cookie_header(cookies: dict) -> str:
    """Build Cookie header value from captured cookies."""
    parts = []
    # Priority order: clearance first
    for name in [CF_CLEARANCE_COOKIE, CF_BM_COOKIE, CF_LB_COOKIE]:
        if name in cookies:
            parts.append(f"{name}={cookies[name]}")
    # Add any other cookies from the domain
    for k, v in cookies.items():
        if k not in (CF_CLEARANCE_COOKIE, CF_BM_COOKIE, CF_LB_COOKIE):
            parts.append(f"{k}={v}")
    return "; ".join(parts)


def write_session(session_file: str, data: dict):
    """Write session.json atomically."""
    tmp = session_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, session_file)
    log(f"session.json written → {session_file}")


# ─── Core harvest logic ───────────────────────────────────────────────────────

def harvest(
    url: str,
    session_file: str,
    override_port: int = None,
    override_path: str = None,
) -> dict | None:
    """
    Open a real Chrome window, wait for the user to solve the CF challenge,
    extract all necessary tokens, return session dict.
    """
    parsed   = urlparse(url)
    scheme   = parsed.scheme or "https"
    host     = parsed.netloc or parsed.path
    path     = override_path or parsed.path or "/"
    if not path:
        path = "/"
    default_port = 443 if scheme == "https" else 80
    port         = override_port or parsed.port or default_port

    # Normalise host (remove port if present)
    if ":" in host:
        host = host.split(":")[0]

    full_url = f"{scheme}://{host}"
    if port not in (80, 443):
        full_url += f":{port}"
    full_url += path

    log(f"Target : {full_url}")
    log(f"Session: {session_file}")

    with sync_playwright() as pw:
        # Launch real visible Chrome — NOT headless
        try:
            browser = pw.chromium.launch(
                headless=False,
                channel="chrome",
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-infobars",
                    "--disable-dev-shm-usage",
                ],
            )
        except Exception:
            # Fallback to Playwright's own Chromium build
            log("Chrome binary not found — falling back to Playwright Chromium")
            browser = pw.chromium.launch(
                headless=False,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-infobars",
                ],
            )

        context = browser.new_context(
            viewport={"width": 1280, "height": 800},
            user_agent=None,  # let Chrome decide
            locale="en-US",
            timezone_id="America/New_York",
        )

        # ── Capture request headers via CDP ───────────────────────────────────
        captured_ua      = ""
        captured_headers = {}
        capture_lock     = {"done": False}

        def on_request(request):
            nonlocal captured_ua, captured_headers
            if capture_lock["done"]:
                return
            req_url = request.url
            if host not in req_url:
                return
            hdrs = dict(request.headers)
            ua   = hdrs.get("user-agent", hdrs.get("User-Agent", ""))
            if ua:
                captured_ua      = ua
                captured_headers = hdrs

        page = context.new_page()
        page.on("request", on_request)

        log("Browser opened. Navigate to the target and solve the CF challenge.")
        log("Waiting for cf_clearance cookie...")

        try:
            page.goto(full_url, timeout=30000, wait_until="domcontentloaded")
        except Exception as e:
            log(f"Initial navigation warning (non-fatal): {e}")

        # ── Poll until cf_clearance appears ───────────────────────────────────
        deadline = time.time() + MAX_WAIT
        cf_clearance_val = ""
        while time.time() < deadline:
            cookies = get_cookies(context, host)
            cf_clearance_val = cookies.get(CF_CLEARANCE_COOKIE, "")
            if cf_clearance_val:
                log(f"cf_clearance captured!")
                capture_lock["done"] = True
                break
            time.sleep(POLL_INTERVAL)
            # Also accept manual navigation — keep checking
            try:
                current_url = page.url
                if host in current_url and not cf_clearance_val:
                    pass  # still waiting
            except Exception:
                pass

        if not cf_clearance_val:
            log("ERROR: Timed out waiting for cf_clearance. Did you solve the challenge?")
            browser.close()
            return None

        # ── Collect final cookies ──────────────────────────────────────────────
        time.sleep(1.5)  # small grace period for __cf_bm to arrive
        cookies      = get_cookies(context, host)
        cookie_hdr   = build_cookie_header(cookies)
        cf_bm_val    = cookies.get(CF_BM_COOKIE, "")
        cf_lb_val    = cookies.get(CF_LB_COOKIE, "")

        # Use captured UA or fall back to page evaluate
        if not captured_ua:
            try:
                captured_ua = page.evaluate("() => navigator.userAgent")
            except Exception:
                captured_ua = (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                )

        # Estimate valid_until: cf_clearance default lifetime is 30 minutes
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
        log(f"All cookies captured. Valid for ~30 minutes.")
        log(f"UA: {captured_ua[:80]}...")

        # ── Auto-refresh loop ─────────────────────────────────────────────────
        log(f"Auto-refresh every {REFRESH_INTERVAL // 60} minutes. Press Ctrl+C to stop.")
        refresh_deadline = time.time() + REFRESH_INTERVAL

        while True:
            now = time.time()
            remaining = int(refresh_deadline - now)

            if remaining <= 0:
                log("Refreshing session...")
                try:
                    page.goto(full_url, timeout=30000, wait_until="domcontentloaded")
                    time.sleep(3)
                    cookies     = get_cookies(context, host)
                    cookie_hdr  = build_cookie_header(cookies)
                    new_clearance = cookies.get(CF_CLEARANCE_COOKIE, cf_clearance_val)

                    if new_clearance != cf_clearance_val:
                        log("New cf_clearance obtained from silent refresh.")
                        cf_clearance_val = new_clearance

                    session["cf_clearance"]  = cookies.get(CF_CLEARANCE_COOKIE, cf_clearance_val)
                    session["cf_bm"]         = cookies.get(CF_BM_COOKIE, "")
                    session["cookie_header"] = build_cookie_header(cookies)
                    session["valid_until"]   = int(time.time()) + 30 * 60
                    session["captured_at"]   = int(time.time())
                    write_session(session_file, session)

                    refresh_deadline = time.time() + REFRESH_INTERVAL
                except Exception as e:
                    log(f"Refresh error: {e} — will retry in 60s")
                    refresh_deadline = time.time() + 60
            else:
                if remaining % 60 == 0:
                    log(f"Next refresh in {remaining // 60}m {remaining % 60}s")
                time.sleep(1)

        browser.close()
        return session


# ─── Entry point ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Vape Ultra v1.2 — Layer 7 CF Session Harvester"
    )
    parser.add_argument("url",          help="Target URL (e.g. https://target.com)")
    parser.add_argument("--session",    default="session.json",
                        help="Output session file (default: session.json)")
    parser.add_argument("--port",       type=int, default=None,
                        help="Override port (default: 443 for https, 80 for http)")
    parser.add_argument("--path",       default=None,
                        help="Override path (default: /)")
    args = parser.parse_args()

    # Ensure URL has a scheme
    url = args.url
    if not url.startswith("http://") and not url.startswith("https://"):
        url = "https://" + url

    # Resolve session file path relative to this script
    session_file = args.session
    if not os.path.isabs(session_file):
        session_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), session_file)

    try:
        harvest(url, session_file, override_port=args.port, override_path=args.path)
    except KeyboardInterrupt:
        log("Stopped by user.")
        sys.exit(0)


if __name__ == "__main__":
    main()
