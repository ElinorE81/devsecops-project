import json
import logging
import math
import os
import time
from datetime import datetime, timezone
from flask import Flask, request, jsonify

app = Flask(__name__)


# ---------------------------------------------------------------------------
# Structured JSON logging — optimized for Splunk key=value field extraction
# ---------------------------------------------------------------------------

class _JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "level": record.levelname,
            "event": record.getMessage(),
        }
        for field in ("ip", "endpoint", "status_code", "duration_ms", "detail"):
            if hasattr(record, field):
                entry[field] = getattr(record, field)
        return json.dumps(entry)


_handler = logging.StreamHandler()
_handler.setFormatter(_JsonFormatter())

logger = logging.getLogger("devsecops")
logger.setLevel(logging.INFO)
logger.addHandler(_handler)
logger.propagate = False  # prevent Flask's default handler from double-logging


# ---------------------------------------------------------------------------
# Request lifecycle hooks
# ---------------------------------------------------------------------------

@app.before_request
def _stamp_start():
    request._start_time = time.perf_counter()


@app.after_request
def _log_request(response):
    duration_ms = round((time.perf_counter() - request._start_time) * 1000, 2)
    level = logging.WARNING if response.status_code >= 400 else logging.INFO
    logger.log(
        level,
        "http_request",
        extra={
            "ip": request.headers.get("X-Forwarded-For", request.remote_addr),
            "endpoint": request.path,
            "status_code": response.status_code,
            "duration_ms": duration_ms,
        },
    )
    return response


# ---------------------------------------------------------------------------
# CPU-intensive helper — trial-division prime count
# Calculating all primes below 15,000 takes ~5-15 ms per request on a
# t2.micro, which is enough to saturate CPU under a Layer 7 flood without
# making individual legitimate requests feel slow.
# ---------------------------------------------------------------------------

def _count_primes(limit: int) -> int:
    count = 0
    for n in range(2, limit + 1):
        if n == 2:
            count += 1
            continue
        if n % 2 == 0:
            continue
        is_prime = True
        for i in range(3, int(math.isqrt(n)) + 1, 2):
            if n % i == 0:
                is_prime = False
                break
        if is_prime:
            count += 1
    return count


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    """
    Main endpoint — performs deliberate CPU work so a Layer 7 HTTP flood
    causes measurable EC2 CPU stress without needing enormous request volume.
    """
    prime_count = _count_primes(15_000)
    return jsonify({
        "status": "ok",
        "service": "devsecops-self-healing-cloud",
        "primes_below_15000": prime_count,
    })


@app.route("/health")
def health():
    """
    ALB health check target — intentionally lightweight; must stay fast so the
    load balancer never marks a healthy instance as unhealthy during a flood.
    """
    return jsonify({"status": "healthy"}), 200


# ---------------------------------------------------------------------------
# Entrypoint (development only — production uses Gunicorn via Dockerfile CMD)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=False)
