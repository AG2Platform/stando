"""Python twin of src/cloud-client.ts — emits usage_events to the cloud
control plane.

Reads the same auth file written by Sutando.app's CloudAuth.swift at
$SUTANDO_HOME/cloud-auth.json. No batching: most Python metering points
(image generation, video generation, occasional Twilio operations) are
low-frequency, so one HTTP request per event is fine. If a hot Python
caller appears later, fold this into a batched sender (see the TS
implementation for the shape).

Failure is silent — telemetry must never crash the caller.

Usage:

    from cloud_metrics import record_event
    record_event("image.gen", units=1, metadata={"model": "gemini-2.5-flash-image"})
"""
from __future__ import annotations

import json
import os
import sys
import threading
from pathlib import Path
from typing import Any
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

__all__ = ["record_event", "is_cloud_signed_in", "load_cloud_auth"]

REPO_DIR = Path(__file__).resolve().parent.parent
_TIMEOUT_SECONDS = 5.0


def _state_root() -> Path:
    home = os.environ.get("SUTANDO_HOME")
    if home:
        return Path(os.path.expanduser(home))
    return REPO_DIR


def _auth_file() -> Path:
    return _state_root() / "cloud-auth.json"


def load_cloud_auth() -> dict[str, Any] | None:
    """Read the cloud auth record. Returns None if signed out."""
    path = _auth_file()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    if not data.get("token") or not data.get("userId") or not data.get("apiBase"):
        return None
    return data


def is_cloud_signed_in() -> bool:
    return load_cloud_auth() is not None


def _send(auth: dict[str, Any], events: list[dict[str, Any]]) -> None:
    """Background-thread sender. Silent on all errors."""
    try:
        body = json.dumps({"events": events}).encode("utf-8")
        req = urlrequest.Request(
            f"{auth['apiBase'].rstrip('/')}/api/usage",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {auth['token']}",
                "Content-Type": "application/json",
            },
        )
        with urlrequest.urlopen(req, timeout=_TIMEOUT_SECONDS):
            pass
    except (HTTPError, URLError, OSError, TimeoutError) as e:
        try:
            print(f"cloud_metrics: send failed: {e}", file=sys.stderr)
        except Exception:  # noqa: BLE001
            pass


def record_event(
    kind: str,
    units: float = 1,
    cost_cents: int | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    """Fire-and-forget cloud telemetry. Returns immediately; the HTTP
    request runs on a daemon thread.

    Args:
        kind: dotted event identifier matching the cloud schema's
              `usage_events.kind` taxonomy (voice.gemini, image.gen, etc.).
        units: how much. Seconds for time-based, count for image.gen, etc.
        cost_cents: optional pre-computed cost. Server can re-derive from
                    `kind` + `units` if absent.
        metadata: optional JSON object — model name, skill name, etc.
    """
    auth = load_cloud_auth()
    if auth is None:
        return
    event: dict[str, Any] = {"kind": kind, "units": units}
    if cost_cents is not None:
        event["costCents"] = cost_cents
    if metadata:
        event["metadata"] = metadata

    t = threading.Thread(target=_send, args=(auth, [event]), daemon=True)
    t.start()
