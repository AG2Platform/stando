#!/usr/bin/env python3
"""Archive stale `results/*.txt` files to `results/archive-YYYY-MM-DD/`.

Run once at system startup (before any service begins iterating `results/`)
so that task-bridge, discord-bridge, and the DM-fallback path never have to
reason about long-dead files they weren't around to consume.

Retention policy: by default, any `.txt` directly under `results/` whose
mtime is older than $RETENTION_HOURS (default 24) gets moved under a
date-stamped archive subdirectory. Files inside existing `archive-*`
subdirectories are never touched.

Usage:
    python3 src/archive-stale-results.py
    RETENTION_HOURS=48 python3 src/archive-stale-results.py      # looser window
    DRY_RUN=1 python3 src/archive-stale-results.py               # print, don't move

Intended caller: `src/startup.sh` runs this before launching services.

Why this exists: on 2026-04-15 the DM fallback wiring iterated `results/`
on voice-agent restart, found 142 stale files accumulated since the prior
day, and fired one DM per file. The flood was stopped by a manual archive
sweep of the same directory. This script automates that sweep and runs it
before services can see the backlog. Full post-mortem:
`notes/post-mortem-dm-flood-2026-04-15.md`.
"""

import os
import sys
import time
from datetime import datetime
from pathlib import Path

# Resolve through SUTANDO_HOME, not Path(__file__).resolve(), because the
# .app bundle ships src/ as a symlink target: resolving __file__ jumps the
# script's home into /Applications/Sutando.app/Contents/Resources/repo/,
# where results/ and tasks/ do not exist. Until 2026-05-13 the script was
# a silent no-op for every install with the bundle layout; only dev clones
# (where src/ is a real dir under SUTANDO_HOME) ever did anything. Use the
# shared state_dir() helper so we end up at $SUTANDO_HOME/{results,tasks}.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from util_paths import state_dir  # noqa: E402

RESULTS = state_dir("results")
TASKS = state_dir("tasks")

RETENTION_HOURS = int(os.environ.get("RETENTION_HOURS", "24"))
# Case-insensitive compare — without `.lower()`, `DRY_RUN=No` or `DRY_RUN=FALSE`
# would silently evaluate truthy (dry-run mode) because "No"/"FALSE" aren't in
# the lowercase reject list. Found in cold-review of #354.
DRY_RUN = os.environ.get("DRY_RUN", "").strip().lower() not in ("", "0", "false", "no")


def sweep(root: Path, label: str, cutoff: float) -> tuple[int, int]:
    """Move stale .txt files in `root` to `root/archive-YYYY-MM-DD/`.

    Returns (moved, errors). Files inside `archive-*` or other subdirs are
    skipped — only top-level .txt files are candidates. Caller logs the
    summary line with `label` (e.g. "results", "tasks") so the two sweeps
    are distinguishable in startup output.
    """
    if not root.is_dir():
        print(f"  [retention] {label}/ missing — nothing to do")
        return 0, 0

    archive_name = datetime.now().strftime("archive-%Y-%m-%d")
    archive_dir = root / archive_name

    moved = 0
    errors = 0
    for f in root.iterdir():
        if not f.is_file():
            continue
        if f.suffix != ".txt":
            continue
        try:
            if f.stat().st_mtime >= cutoff:
                continue
        except FileNotFoundError:
            continue
        if DRY_RUN:
            print(f"  [retention] would archive {label}/{f.name}")
            moved += 1
            continue
        if not archive_dir.exists():
            archive_dir.mkdir(parents=True, exist_ok=True)
        try:
            f.rename(archive_dir / f.name)
            moved += 1
        except Exception as e:
            print(f"  [retention] failed to archive {label}/{f.name}: {e}", file=sys.stderr)
            errors += 1

    word = "would archive" if DRY_RUN else "archived"
    if moved or errors:
        print(
            f"  [retention] {word} {moved} stale {label} file(s) (>{RETENTION_HOURS}h)"
            + (f", {errors} error(s)" if errors else "")
            + (f" to {label}/{archive_dir.name}/" if moved and not DRY_RUN else "")
        )
    else:
        print(f"  [retention] no stale {label} files to archive (>{RETENTION_HOURS}h cutoff)")
    return moved, errors


def main() -> int:
    cutoff = time.time() - RETENTION_HOURS * 3600
    # Sweep results/ first (legacy behaviour), then tasks/. tasks/ accumulation
    # came from the web/api source — agent-api.py writes task files but has no
    # post-reply cleanup, unlike discord-bridge.py and task-bridge.ts which
    # archive after sending the reply. Diagnosed 2026-05-13.
    _, e1 = sweep(RESULTS, "results", cutoff)
    _, e2 = sweep(TASKS, "tasks", cutoff)
    return 1 if (e1 + e2) else 0


if __name__ == "__main__":
    sys.exit(main())
