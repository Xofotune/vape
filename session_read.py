#!/usr/bin/env python3
"""
session_read.py — Vape Ultra session.json utility
Developer: @Paxjest

Used by the attack wrapper to safely read session.json without
fragile inline shell/Python escaping.

Usage:
    python3 session_read.py <session.json> <field>
    python3 session_read.py <session.json> valid     # exits 0 if valid, 1 if expired
    python3 session_read.py <session.json> args      # prints: host port
    python3 session_read.py <session.json> host
    python3 session_read.py <session.json> port
    python3 session_read.py <session.json> all       # pretty-print full session
"""

import json
import sys
import time
import os


def load(path: str) -> dict:
    if not os.path.isfile(path):
        print(f"[session_read] ERROR: {path} not found", file=sys.stderr)
        sys.exit(2)
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        print(f"[session_read] ERROR: cannot parse {path}: {e}", file=sys.stderr)
        sys.exit(2)


def is_valid(d: dict) -> bool:
    vu = int(d.get("valid_until", 0))
    cf = d.get("cf_clearance", "")
    host = d.get("host", "")
    return bool(cf) and bool(host) and vu > time.time() + 60


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    path  = sys.argv[1]
    field = sys.argv[2].lower()
    d     = load(path)

    if field == "valid":
        if is_valid(d):
            remaining = int(d.get("valid_until", 0)) - int(time.time())
            print(f"VALID  (expires in {remaining // 60}m {remaining % 60}s)")
            sys.exit(0)
        else:
            vu = int(d.get("valid_until", 0))
            if vu < time.time():
                print("EXPIRED")
            elif not d.get("cf_clearance"):
                print("MISSING_CF_CLEARANCE")
            elif not d.get("host"):
                print("MISSING_HOST")
            else:
                print("INVALID")
            sys.exit(1)

    elif field == "args":
        # Outputs: host port   (one per line for easy shell read)
        host = d.get("host", "")
        port = str(d.get("port", 443))
        if not host:
            print("[session_read] ERROR: host field empty", file=sys.stderr)
            sys.exit(2)
        print(host)
        print(port)

    elif field == "all":
        d_display = dict(d)
        # Truncate long fields for display
        for k in ("cf_clearance", "cf_bm", "cf_lb", "cookie_header"):
            if k in d_display and len(str(d_display[k])) > 60:
                d_display[k] = str(d_display[k])[:57] + "..."
        # valid_until to human time
        if "valid_until" in d_display:
            vu = int(d_display["valid_until"])
            remaining = vu - int(time.time())
            d_display["valid_until_human"] = (
                f"{remaining // 60}m {remaining % 60}s remaining"
                if remaining > 0 else "EXPIRED"
            )
        print(json.dumps(d_display, indent=2))

    else:
        val = d.get(field)
        if val is None:
            print(f"[session_read] WARNING: field '{field}' not found", file=sys.stderr)
            sys.exit(2)
        print(val)


if __name__ == "__main__":
    main()
