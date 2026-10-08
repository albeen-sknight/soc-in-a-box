"""
The pager relay.

Splunk's webhook sends a block of JSON when an alert fires. A phone can't do much with raw JSON,
so this small server catches it, turns it into a short message a person can read at 23:00,
and pushes it to my phone through ntfy.

It only uses Python's standard library, and it only listens inside Docker's network:
nothing outside the PC can reach it.
"""
import json
import os
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
NTFY_TOPIC = os.environ["NTFY_TOPIC"]          # secret: lives only in .env
PRIORITY_NAMES = {"3": "Medium", "4": "High", "5": "Critical"}

# Splunk's own bookkeeping fields, which mean nothing on a phone
SKIP_FIELDS = {"_time", "_raw", "_bkt", "_cd", "_si", "_serial", "_indextime", "_sourcetype", "linecount", "splunk_server"}


def build_message(payload: dict) -> str:
    """Pick the first few useful fields from the first result, one per line."""
    result = payload.get("result") or {}
    lines = []
    for key, value in result.items():
        if key in SKIP_FIELDS or key.startswith("_"):
            continue
        if isinstance(value, list):
            value = ", ".join(str(v) for v in value)
        lines.append(f"{key}: {value}")
        if len(lines) == 6:
            break
    return "\n".join(lines) or "Open Splunk to see the results."


def send_to_phone(title: str, message: str, priority: str) -> None:
    request = urllib.request.Request(
        f"{NTFY_SERVER}/{NTFY_TOPIC}",
        data=message.encode("utf-8"),
        method="POST",
        headers={
            "Title": title.encode("ascii", "replace").decode("ascii"),
            "Priority": priority,
            "Tags": "rotating_light" if priority in ("4", "5") else "warning",
        },
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        # The priority comes from the webhook address in savedsearches.conf, for example /alert?priority=4
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        priority = query.get("priority", ["4"])[0]
        if priority not in PRIORITY_NAMES:
            priority = "4"

        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            payload = {}

        name = payload.get("search_name", "Unknown alert")
        title = f"[{PRIORITY_NAMES[priority]}] {name}"
        try:
            send_to_phone(title, build_message(payload), priority)
            print(f"Paged: {title}", flush=True)
            self.send_response(200)
        except Exception as error:  # keep the relay alive whatever ntfy says
            print(f"Could not page for {name}: {error}", flush=True)
            self.send_response(502)
        self.end_headers()

    def log_message(self, *args):
        pass  # my own print lines are enough


if __name__ == "__main__":
    print("Pager relay listening on port 8000", flush=True)
    HTTPServer(("0.0.0.0", 8000), AlertHandler).serve_forever()
