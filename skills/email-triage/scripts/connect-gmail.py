#!/usr/bin/env python3
"""Connect (or verify) Gmail/Google Workspace via the `gws` CLI.

Why this exists (feedback 6bad56a2 — "Sutando is still not helpful to set up
Gmail"): the agent used to open a Google sign-in window and then say "confirm
on your end if you've finished" — it had no way to KNOW whether sign-in
succeeded, so a user who signed in three times still got asked to confirm.
This helper makes connection state programmatically verifiable:

  connect-gmail.py --check   # report state only, NO browser, NO side effects.
                             # exit 0 = connected, 1 = not. The completion
                             # detector — safe to poll after the user signs in.

  connect-gmail.py           # drive the full connect: ensure an OAuth client
                             # exists, open the browser sign-in, BLOCK until it
                             # finishes, then verify. Prints CONNECTED / FAILED
                             # with a concrete reason — never "confirm on your
                             # end."

The agent should run this and report the final line + exit code truthfully,
rather than narrating an unverified sign-in.
"""

import argparse
import json
import shutil
import subprocess
import sys

LOGIN_TIMEOUT_S = 180  # how long to wait for the browser OAuth round-trip
PROBE_TIMEOUT_S = 15


def _run(args, timeout, stdin_devnull=True):
    """Run a command, return (returncode, stdout, stderr). -1 rc on timeout."""
    try:
        p = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL if stdin_devnull else None,
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"timed out after {timeout}s"
    except OSError as e:
        return -2, "", str(e)


def auth_status():
    """Parse `gws auth status` JSON, or None if unavailable."""
    rc, out, _ = _run(["gws", "auth", "status"], timeout=10)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except (json.JSONDecodeError, ValueError):
        return None


def _has_credentials(status) -> bool:
    """True when gws reports a usable credential source (not 'none')."""
    if not status:
        return False
    method = (status.get("auth_method") or "none").lower()
    source = (status.get("credential_source") or "none").lower()
    return method != "none" and source != "none"


def probe_gmail() -> bool:
    """Definitive check: a real read-only Gmail API call must succeed.

    Guards against credentials that exist but lack the Gmail scope.
    """
    rc, out, _ = _run(["gws", "gmail", "+triage", "--max", "1", "--format", "json"], timeout=PROBE_TIMEOUT_S)
    if rc != 0:
        return False
    # gws prints diagnostic header lines before the JSON object; find it.
    for i, ch in enumerate(out):
        if ch == "{":
            try:
                json.loads(out[i:])
                return True
            except (json.JSONDecodeError, ValueError):
                return False
    return False


def is_connected() -> bool:
    return _has_credentials(auth_status()) and probe_gmail()


def gcloud_project():
    if not shutil.which("gcloud"):
        return None
    rc, out, _ = _run(["gcloud", "config", "get-value", "project"], timeout=10)
    proj = (out or "").strip()
    return proj if (rc == 0 and proj and proj != "(unset)") else None


def emit_check():
    """--check: state-only, no side effects. The completion detector."""
    connected = is_connected()
    print(json.dumps({"connected": connected}))
    print("Gmail is connected." if connected else "Gmail is NOT connected.")
    return 0 if connected else 1


def drive_connect():
    if not shutil.which("gws"):
        print("FAILED: the Google Workspace CLI (gws) isn't installed.")
        print("Install it first:  npm i -g @googleworkspace/cli")
        return 3

    if is_connected():
        print("ALREADY CONNECTED: Gmail is set up and a live API call succeeded.")
        return 0

    status = auth_status() or {}

    # No OAuth client yet → sign-in has nothing to authorize against. This is
    # the usual reason "open a sign-in window" silently does nothing.
    if not status.get("client_config_exists", False) and not _has_credentials(status):
        project = gcloud_project()
        if project:
            print(f"No OAuth client yet — running one-time setup (gcloud project: {project}) + sign-in...")
            rc, out, err = _run(["gws", "auth", "setup", "--login", "--project", project], timeout=LOGIN_TIMEOUT_S)
            if rc != 0:
                print("FAILED: one-time OAuth client setup did not complete.")
                print((err or out or "").strip()[:500])
                return 4
        else:
            print("FAILED: Gmail needs a one-time Google OAuth client before sign-in can work (none configured).")
            print("Pick ONE:")
            print("  • Install the gcloud CLI, then re-run me — I'll create the client + sign you in:")
            print("      brew install --cask google-cloud-sdk && gcloud auth login")
            print("  • Or create an OAuth *Desktop* client at")
            print("      https://console.cloud.google.com/apis/credentials")
            print("    and save it to ~/.config/gws/client_secret.json, then re-run me.")
            return 4
    else:
        # Client exists but no live credentials → just sign in.
        print("Opening the Google sign-in window — finish signing in there; I'll wait and verify...")
        rc, out, err = _run(["gws", "auth", "login", "--services", "gmail,calendar"], timeout=LOGIN_TIMEOUT_S)
        if rc == -1:
            print(f"Sign-in didn't complete within {LOGIN_TIMEOUT_S}s — checking anyway...")

    # Verify the end state regardless of how we got here.
    if is_connected():
        print("CONNECTED: Gmail sign-in verified — a live read-only API call succeeded.")
        return 0
    print("FAILED: sign-in did not result in a working Gmail connection.")
    print("Re-run me to try again, or check `gws auth status`.")
    return 1


def main():
    ap = argparse.ArgumentParser(description="Connect or verify Gmail via gws.")
    ap.add_argument("--check", action="store_true",
                    help="Report connection state only (no browser, no side effects). exit 0=connected, 1=not.")
    args = ap.parse_args()
    sys.exit(emit_check() if args.check else drive_connect())


if __name__ == "__main__":
    main()
