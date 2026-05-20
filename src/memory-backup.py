#!/usr/bin/env python3
"""Cloud memory backup — upload + hydrate $SUTANDO_MEMORY_DIR (+ notes).

Beta posture: PLAINTEXT. The cloud snapshot route stores ciphertext only
if we send ciphertext, but the user-passphrase / E2E key-derivation path
is deferred per scope discussion. PRODUCT.md §3 has been updated to
reflect that the "cloud cannot read your memory" claim is process-/access-
controlled in beta, not mathematically guaranteed. End-to-end encryption
is a post-beta upgrade.

Commands:

    python3 src/memory-backup.py upload         # tar+gzip → /api/memory/snapshot
    python3 src/memory-backup.py hydrate        # download latest snapshot if memory dir empty
    python3 src/memory-backup.py status         # print sign-in + plan + last upload

Exit codes:
    0  success (or no-op: signed out / not paid)
    1  configuration error (missing $SUTANDO_HOME)
    2  upload / download HTTP failure
    3  tar / extract failure
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cloud_metrics import load_cloud_auth  # noqa: E402
from workspace_default import resolve_workspace  # noqa: E402
from util_paths import shared_personal_path  # noqa: E402


PAID_PLANS = {"plus", "pro", "max"}
TIMEOUT_SECONDS = 30.0


def memory_dir() -> Path:
    """Return the canonical $SUTANDO_MEMORY_DIR (or the default Claude
    project directory). Created if missing."""
    explicit = os.environ.get("SUTANDO_MEMORY_DIR")
    if explicit:
        p = Path(os.path.expanduser(explicit))
    else:
        p = Path.home() / ".claude" / "projects" / "-Users-lianghaochen-stando" / "memory"
    p.mkdir(parents=True, exist_ok=True)
    return p


def notes_dir() -> Path:
    """Return the notes/ directory (memory-dir-first, workspace fallback)."""
    return shared_personal_path("notes")


def state_dir() -> Path:
    return resolve_workspace(migrate=False) / "state"


def _log(msg: str) -> None:
    print(f"[memory-backup] {msg}", flush=True)


def _fetch_plan(auth: dict[str, Any]) -> str | None:
    """Read users.plan via GET /api/me. Returns None on any failure."""
    try:
        req = urlrequest.Request(
            f"{auth['apiBase'].rstrip('/')}/api/me",
            method="GET",
            headers={"Authorization": f"Bearer {auth['token']}"},
        )
        with urlrequest.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body)
            plan = data.get("plan")
            return str(plan) if isinstance(plan, str) else None
    except (HTTPError, URLError, OSError, TimeoutError, json.JSONDecodeError):
        return None


def _make_tarball(out_path: Path) -> bool:
    """Tar up the memory + notes directories into a single .tar.gz.
    Skips when both source dirs are empty so we don't churn 0-byte
    snapshots before the user has produced anything."""
    mdir = memory_dir()
    ndir = notes_dir()
    mempaths_empty = not any(mdir.iterdir())
    notes_empty = (not ndir.exists()) or not any(ndir.iterdir())
    if mempaths_empty and notes_empty:
        _log("memory + notes both empty — nothing to upload")
        return False

    args = ["tar", "-czf", str(out_path)]
    # Preserve relative directory shape inside the tarball so hydrate
    # can extract back into the same parents.
    if mdir.exists() and any(mdir.iterdir()):
        args += ["-C", str(mdir.parent), mdir.name]
    if ndir.exists() and any(ndir.iterdir()):
        args += ["-C", str(ndir.parent), ndir.name]

    try:
        subprocess.run(args, check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError as e:
        _log(f"tar failed: {e.stderr.decode('utf-8', errors='replace')[:200]}")
        return False


def cmd_upload() -> int:
    auth = load_cloud_auth()
    if auth is None:
        _log("not signed in — skipping")
        return 0
    plan = _fetch_plan(auth)
    if plan is None:
        _log("could not fetch plan — skipping")
        return 0
    if plan not in PAID_PLANS:
        _log(f"plan={plan} — paid tier required for cloud memory backup")
        return 0

    with tempfile.TemporaryDirectory(prefix="sutando-snapshot-") as td:
        tarball = Path(td) / "snapshot.tar.gz"
        if not _make_tarball(tarball):
            return 0
        size = tarball.stat().st_size
        _log(f"uploading {size} bytes")
        try:
            with tarball.open("rb") as f:
                data = f.read()
            req = urlrequest.Request(
                f"{auth['apiBase'].rstrip('/')}/api/memory/snapshot",
                data=data,
                method="POST",
                headers={
                    "Authorization": f"Bearer {auth['token']}",
                    "Content-Type": "application/gzip",
                },
            )
            with urlrequest.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                _log(f"upload OK: {body[:200]}")
                _write_last_upload_marker()
                return 0
        except HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")[:300] if e.fp else ""
            _log(f"upload HTTP {e.code}: {detail}")
            # 503 = bucket creds not provisioned; treat as success-no-op.
            return 0 if e.code == 503 else 2
        except (URLError, OSError, TimeoutError) as e:
            _log(f"upload network error: {e}")
            return 2


def _write_last_upload_marker() -> None:
    try:
        state = state_dir()
        state.mkdir(parents=True, exist_ok=True)
        (state / "memory-backup-last-upload.json").write_text(
            json.dumps({"ts": int(time.time())})
        )
    except OSError:
        pass


def cmd_hydrate() -> int:
    """Download the latest snapshot and extract IF the local memory dir
    is empty. Used by the menu-bar app on first launch after a fresh
    install or a sign-in on a new Mac. Never overwrites existing files."""
    auth = load_cloud_auth()
    if auth is None:
        _log("not signed in — skipping hydrate")
        return 0
    mdir = memory_dir()
    if any(mdir.iterdir()):
        _log("memory dir not empty — skipping hydrate (would overwrite local state)")
        return 0

    try:
        req = urlrequest.Request(
            f"{auth['apiBase'].rstrip('/')}/api/memory/snapshot",
            method="GET",
            headers={"Authorization": f"Bearer {auth['token']}"},
        )
        with urlrequest.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
    except (HTTPError, URLError, OSError, TimeoutError, json.JSONDecodeError) as e:
        _log(f"hydrate fetch failed: {e}")
        return 2

    if not data.get("configured"):
        _log("cloud backup not configured — skipping")
        return 0
    snap = data.get("snapshot")
    if not snap or not isinstance(snap, dict):
        _log("no snapshot to restore")
        return 0
    download_url = snap.get("downloadUrl")
    if not isinstance(download_url, str):
        _log("snapshot missing downloadUrl — server bug?")
        return 2

    with tempfile.TemporaryDirectory(prefix="sutando-hydrate-") as td:
        tarball = Path(td) / "snapshot.tar.gz"
        try:
            req = urlrequest.Request(download_url, method="GET")
            with urlrequest.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                tarball.write_bytes(resp.read())
            _log(f"downloaded {tarball.stat().st_size} bytes")
        except (HTTPError, URLError, OSError, TimeoutError) as e:
            _log(f"download failed: {e}")
            return 2

        # Extract into the parent of memory_dir so the tarball's
        # directory structure overlays correctly.
        target_root = mdir.parent
        try:
            subprocess.run(
                ["tar", "-xzf", str(tarball), "-C", str(target_root)],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            _log(f"extract failed: {e.stderr.decode('utf-8', errors='replace')[:200]}")
            return 3

    _log("hydrate complete")
    return 0


def cmd_status() -> int:
    auth = load_cloud_auth()
    if auth is None:
        print("signed_in: false")
        return 0
    plan = _fetch_plan(auth) or "unknown"
    paid = plan in PAID_PLANS
    print(f"signed_in: true")
    print(f"plan: {plan}")
    print(f"paid_tier: {paid}")
    last_marker = state_dir() / "memory-backup-last-upload.json"
    if last_marker.exists():
        try:
            data = json.loads(last_marker.read_text())
            print(f"last_upload_ts: {data.get('ts')}")
        except (json.JSONDecodeError, OSError):
            pass
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "upload":
        return cmd_upload()
    if cmd == "hydrate":
        return cmd_hydrate()
    if cmd == "status":
        return cmd_status()
    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
