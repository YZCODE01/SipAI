#!/usr/bin/env python3
"""A stand-in for Kimi Code's managed API, for the UsageWindow harness.

Answers GET .../usages with one fixed quota, in the upstream shape the
installed kimi parses itself (its `parseManagedUsagePayload`:
`usages.limit_5h / limit_7d / limit_month_total / limit_month_code`
as `{used_ratio, reset_time}`, and a `boosterWallet` whose amounts are
fixed-point, 1e6 per cent). The harness points a real `kimi web` at it
through KIMI_CODE_BASE_URL and reads back what kimi's own usage route
makes of it: the wire shape SipAI's reader has to follow.

It also answers GET .../me — the account kimi's own usage server names
the membership from (`parseManagedUserInfoPayload`: `user_id` and
`user_level_name` in snake_case) — with a synthetic account, so the
harness can read the membership's name back through kimi's route.

Every request is appended to <record-file> as one JSON line holding its
path and whether it carried the planted bearer, so the harness can tell
the route went through kimi's own login slot. Anything but .../usages
and .../me answers 404. Nothing here reaches Moonshot.

Usage:  kimi_upstream.py <record-file>
The port is printed on stdout as `PORT=<n>` once bound.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EXPECTED_BEARER = "Bearer harness-token"

QUOTA = {
    "usages": {
        "limit_5h": {"used_ratio": 0.42, "reset_time": "2026-10-10T20:00:00Z"},
        "limit_7d": {"used_ratio": 0.125, "reset_time": "2026-10-14T04:00:00.000Z"},
        "limit_month_total": {"used_ratio": 0.45, "reset_time": "2026-11-01T00:00:00Z"},
        "limit_month_code": {"used_ratio": 0.15},
    },
    "boosterWallet": {
        "balance": {"type": "BOOSTER", "amount": 2000 * 1000000, "amountLeft": 1250 * 1000000},
        "monthlyChargeLimitEnabled": True,
        "monthlyChargeLimit": {"priceInCents": 5000, "currency": "USD"},
        "monthlyUsed": {"priceInCents": 300, "currency": "USD"},
    },
}


ACCOUNT = {
    "user_id": "u-harness",
    "nickname": "Harness",
    "status": "active",
    "region": "cn",
    "user_level": 20,
    "user_level_name": "Allegretto",
    "domain": 1,
    "domain_name": "",
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        record = {
            "path": self.path,
            "bearer": self.headers.get("Authorization") == EXPECTED_BEARER,
        }
        with open(RECORD, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        path = self.path.split("?", 1)[0]
        if path.endswith("/usages"):
            self.answer(200, QUOTA)
        elif path.endswith("/me"):
            self.answer(200, ACCOUNT)
        else:
            self.answer(404, {"error": "not found"})

    def answer(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    RECORD = sys.argv[1]
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(f"PORT={server.server_address[1]}", flush=True)
    server.serve_forever()
