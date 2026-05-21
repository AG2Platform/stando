#!/usr/bin/env python3
"""Adoption test for `state_paths` / `state-paths` workspace contract.

## Why this test exists

Of the last 250 commits on this repo, roughly **9 are fixes** of the
exact same shape: "module X writes/reads to `tasks/` / `results/` /
`state/` / `notes/` without going through the canonical workspace
resolver, so on `SUTANDO_WORKSPACE`-set hosts the module writes one
place while another component reads another — split-brain that
strands owner DMs / loses voice-agent state / pollutes `git status`."

Sample:
  - PR #843 voice-agent honor SUTANDO_WORKSPACE
  - PR #855 voice-state.json reader+writer honor SUTANDO_WORKSPACE
  - PR #849 core-status.json
  - b51659e fix(bridges,webhook,archive,event-log,notify): route runtime state through state_dir/state_path
  - ab537d0 fix(voice,tmux-status): mkdir data/ before metrics write
  - 38ae961 fix(health-check): resolve .env via state_path
  - 1f29861 mini: heartbeat + core-status paths honor SUTANDO_HOME
  - 8e93c14 merge(CP-0): fix test suite + 2 missed runtime-state paths
  - PR #27 (this round): anchor relative SUTANDO_WORKSPACE absolute

Each was a one-off "found another one, patched another one" fix. The
underlying class — a new source file written without the workspace
contract in mind — keeps producing instances.

## What this test does

For every source file under `src/`, this test:

  1. Scans for **string literals or path expressions** that look like
     references to runtime-state directories (`tasks/`, `results/`,
     `state/`, `notes/`, `data/`, `logs/`).
  2. Requires the file to **either** import the canonical resolver
     (`workspace_default.resolve_workspace` for .py /
     `workspace_default.resolveWorkspace` for .ts) **or** the
     fork's convenience wrapper (`state_paths.state_dir/state_path`
     for .py / `state-paths.stateDir/statePath` for .ts) **or** be
     in an explicit allowlist of files that legitimately reference
     these strings without runtime-state semantics (e.g., the
     wrappers themselves, doc strings in tests).

If a new source file references `tasks/` etc. but doesn't import the
resolver, this test fails — the contributor must either route through
the resolver or add their file to the allowlist with a justification.

The test is a preventative net, not a catch-the-current-violator
check. Any file that currently violates the contract has already
been patched in the historical fixes listed above; the goal is to
keep that work paid down.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"

# Patterns that indicate a file is touching runtime-state directories.
# Match against the file source as a single string. We look for the
# directory name immediately preceded by a path-separator-ish character
# so plain English mentions ("in the tasks dir") don't false-positive.
RUNTIME_STATE_REGEX = re.compile(
    r'(?:'
    # `Path(...) / "tasks"` / `os.path.join(..., "tasks")` / `f".../tasks/..."`
    r'"\s*(?:tasks|results|state|notes|data|logs)\s*"|'
    # `/tasks/`, `/results/` etc. inside a path-literal string
    r"'/(?:tasks|results|state|notes|data|logs)/'|"
    r'"/(?:tasks|results|state|notes|data|logs)/"|'
    # `(REPO|workspace|home|cwd) / "tasks"` (Python path operator)
    r'(?:REPO|REPO_DIR|WORKSPACE_DIR|workspace|repo)\s*/\s*"(?:tasks|results|state|notes|data|logs)"'
    r')'
)

# Canonical accessors. A file that references runtime-state must use one.
PY_CANONICAL = re.compile(
    r'(?:'
    r'from\s+state_paths\s+import|'
    r'import\s+state_paths|'
    r'from\s+workspace_default\s+import|'
    r'import\s+workspace_default|'
    r'state_dir\s*\(|'
    r'state_path\s*\(|'
    r'resolve_workspace\s*\('
    r')'
)
TS_CANONICAL = re.compile(
    r"(?:"
    r"from\s+['\"]\./state-paths['\"]|"
    r"from\s+['\"]\./state_paths['\"]|"
    r"from\s+['\"]\./workspace_default['\"]|"
    r"stateDir\s*\(|"
    r"statePath\s*\(|"
    r"statePathEnsured\s*\(|"
    r"resolveWorkspace\s*\("
    r")"
)

# Files that legitimately reference these strings without runtime-state
# semantics. Each entry is justified in this list, not silently allowed.
#
# Two categories of entries:
#   1. CANONICAL — the resolver modules themselves and a few files that
#      pre-date or intentionally bypass the wrapper convention.
#   2. MIGRATION-PENDING — current violators that use the historic
#      `Path(__file__).parent.parent` anti-pattern. Each one is a
#      latent SUTANDO_WORKSPACE bug on env-set hosts: the file reads
#      from / writes to the repo root instead of the user's workspace.
#      Listed here (not silently passing) so the migration is visible
#      and can be tracked.
ALLOWLIST = {
    # --- CANONICAL ---
    "src/state_paths.py",
    "src/workspace_default.py",
    # util_paths is identical to upstream sonichi/sutando and predates
    # the wrapper convention — but it never writes runtime-state itself
    # (just reads personal-asset paths).
    "src/util_paths.py",
    # core_heartbeat is intentionally dep-free (per its own comment at
    # line 47) — it must run before any other Sutando module is loaded,
    # so it inlines the workspace resolution logic rather than importing
    # workspace_default. Verified inline logic matches the canonical
    # resolver's default-case behavior.
    "src/core_heartbeat.py",

    # --- MIGRATION-PENDING ---
    # The following files use `Path(__file__).parent.parent` (the historic
    # repo-root anti-pattern). On SUTANDO_WORKSPACE-set hosts they
    # read/write at the wrong location. Each needs a follow-up PR to
    # adopt `resolve_workspace()` from workspace_default. Listed here
    # so a NEW file using the anti-pattern fails the test, while the
    # known set remains visible.
    #
    # TODO: migrate to resolve_workspace() — file-by-file PRs.
    "src/call-stats.py",                # CALLS_FILE = repo_root/results/calls/calls.jsonl
    "src/check-pending-questions.py",   # WORKSPACE = repo_root, reads pending-questions.md
    "src/daily-insight.py",             # CALLS_FILE = repo_root/results/calls/calls.jsonl
    "src/detect-learned-skills.py",     # TASKS_ARCHIVE = repo_root/tasks/archive
    "src/friction-detector.py",         # RESULTS_DIR = repo_root/results
    "src/scan-call-logs.py",            # CALLS_FILE + STATE_FILE = repo_root/results/calls/
}


def _check_file(path: Path) -> tuple[bool, str]:
    """Return (ok, reason). ok=True if the file is compliant."""
    rel = path.relative_to(REPO).as_posix()
    if rel in ALLOWLIST:
        return True, "allowlisted"
    try:
        src = path.read_text()
    except Exception as e:
        return True, f"unreadable ({e}); skipping"

    if not RUNTIME_STATE_REGEX.search(src):
        return True, "no runtime-state references"

    canonical_re = TS_CANONICAL if path.suffix in (".ts", ".tsx") else PY_CANONICAL
    if canonical_re.search(src):
        return True, "uses canonical accessor"

    # Find the first offending line for a helpful error message.
    for lineno, line in enumerate(src.split("\n"), 1):
        if RUNTIME_STATE_REGEX.search(line):
            return False, (
                f"{rel}:{lineno}: references a runtime-state path "
                f"({line.strip()!r}) without importing the canonical resolver. "
                f"Use `state_paths.state_dir/state_path` (or `resolve_workspace`) "
                f"in .py, or `state-paths.stateDir/statePath` (or "
                f"`resolveWorkspace`) in .ts. If this file legitimately "
                f"references these strings for non-runtime reasons, add "
                f"{rel!r} to the ALLOWLIST in this test with a justification."
            )
    return True, "no offending line found"  # shouldn't reach


def test_no_unauthorized_runtime_state_references():
    """Every src/*.py and src/*.ts that references `tasks/` / `results/`
    / `state/` / `notes/` / `data/` / `logs/` as a path component must
    go through the canonical workspace resolver."""
    failures = []
    for path in sorted(SRC.rglob("*.py")):
        # Skip dunder dirs / __pycache__
        if "/__pycache__/" in str(path):
            continue
        ok, reason = _check_file(path)
        if not ok:
            failures.append(reason)
    for path in sorted(SRC.rglob("*.ts")):
        if "/node_modules/" in str(path):
            continue
        ok, reason = _check_file(path)
        if not ok:
            failures.append(reason)
    if failures:
        msg = "state-paths adoption violations:\n" + "\n".join(f"  - {f}" for f in failures)
        raise AssertionError(msg)


def test_canonical_modules_themselves_are_present():
    """Sanity: the wrappers we require everyone else to use must exist.
    Catches a refactor that accidentally deletes the canonical module."""
    assert (SRC / "state_paths.py").is_file(), "src/state_paths.py missing"
    assert (SRC / "state-paths.ts").is_file(), "src/state-paths.ts missing"
    assert (SRC / "workspace_default.py").is_file(), "src/workspace_default.py missing"


def test_allowlist_entries_actually_exist():
    """Guard: an ALLOWLIST entry that no longer exists (file renamed /
    deleted) is dead config. Forces ALLOWLIST to stay honest."""
    for entry in ALLOWLIST:
        path = REPO / entry
        if not path.is_file():
            # Allow allowlist to mention not-yet-existing files? No —
            # an allowlist is for known files. Stale entries hide intent.
            raise AssertionError(
                f"ALLOWLIST entry {entry!r} does not exist — remove it from the "
                f"test if the file was deleted/renamed, or add the file back."
            )


def main():
    failures = []
    for fn in (
        test_no_unauthorized_runtime_state_references,
        test_canonical_modules_themselves_are_present,
        test_allowlist_entries_actually_exist,
    ):
        try:
            fn()
            print(f"  ✓ {fn.__name__}")
        except AssertionError as e:
            failures.append(f"{fn.__name__}: {e}")
            print(f"  ✗ {fn.__name__}")
    if failures:
        print("\nFailures:")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    print("All state-paths adoption tests passed.")


if __name__ == "__main__":
    main()
