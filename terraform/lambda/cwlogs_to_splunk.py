"""
CloudWatch Logs → Splunk HEC forwarder.

Triggered by a CloudWatch Logs subscription filter on the application log group.
Each invocation receives a batch of compressed log events, decodes them, and
POSTs each event to the Splunk HTTP Event Collector.

The Flask app emits structured JSON logs so Splunk receives parsed key=value
fields directly — no additional field extraction configuration required.
"""
import base64
import gzip
import json
import os
import urllib.error
import urllib.request

SPLUNK_HEC_URL = os.environ["SPLUNK_HEC_URL"]    # full URL incl. /services/collector
SPLUNK_HEC_TOKEN = os.environ["SPLUNK_HEC_TOKEN"]
SPLUNK_INDEX = os.environ.get("SPLUNK_INDEX", "devsecops_security")


def handler(event, context):
    # CloudWatch Logs delivers events as base64-encoded gzipped JSON
    compressed = base64.b64decode(event["awslogs"]["data"])
    payload = json.loads(gzip.decompress(compressed))

    log_group = payload["logGroup"]
    log_stream = payload["logStream"]

    splunk_events = []
    for log_event in payload["logEvents"]:
        # Try to forward structured JSON as-is so Splunk sees typed fields;
        # fall back to the raw string for non-JSON lines (e.g. Gunicorn startup).
        try:
            message = json.loads(log_event["message"])
        except (json.JSONDecodeError, TypeError):
            message = log_event["message"]

        splunk_events.append(json.dumps({
            "time": log_event["timestamp"] / 1000,   # epoch seconds (float)
            "host": log_stream,
            "source": log_group,
            "sourcetype": "app:flask",
            "index": SPLUNK_INDEX,
            "event": message,
        }))

    body = "\n".join(splunk_events).encode()

    req = urllib.request.Request(
        SPLUNK_HEC_URL,
        data=body,
        headers={
            "Authorization": f"Splunk {SPLUNK_HEC_TOKEN}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            print(f"Splunk HEC accepted {len(splunk_events)} event(s): {result}")
            return result
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode()
        print(f"Splunk HEC HTTP {exc.code}: {error_body}")
        raise
