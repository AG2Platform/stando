#!/usr/bin/env python3
"""Detect repeated workflow patterns and propose learned skill candidates.

Reads task archives from the last 30 days. Groups tasks by semantic
similarity using TF-IDF-style word overlap scoring. When a cluster
reaches N=4 occurrences, writes a candidate skill bundle to
learned-skills/<slug>/ and queues a yes/no question in pending-questions.md.

Gated by state/learned-skills-enabled.sentinel (off by default).
Run from the proactive loop: python3 src/detect-learned-skills.py
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

WORKSPACE = Path(__file__).parent.parent
TASKS_ARCHIVE = WORKSPACE / "tasks" / "archive"
LEARNED_DIR = WORKSPACE / "learned-skills"
STATE_DIR = WORKSPACE / "state"
PENDING_Q = WORKSPACE / "pending-questions.md"

ENABLED_SENTINEL = STATE_DIR / "learned-skills-enabled.sentinel"
N_THRESHOLD = 4       # occurrences before proposing a skill
WINDOW_DAYS = 30      # look-back window
SIM_THRESHOLD = 0.35  # cosine similarity threshold for "same intent"

STOPWORDS = {
    "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
    "of", "with", "by", "from", "up", "about", "into", "through", "during",
    "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
    "do", "does", "did", "will", "would", "could", "should", "may", "might",
    "can", "shall", "it", "its", "this", "that", "these", "those", "i",
    "my", "me", "you", "your", "we", "our", "they", "their", "he", "she",
    "then", "than", "so", "if", "as", "not", "no", "just", "also", "some",
    "any", "all", "more", "most", "other", "please", "need", "want",
}


def is_enabled() -> bool:
    return ENABLED_SENTINEL.exists()


def load_recent_tasks(days: int = WINDOW_DAYS) -> list[dict]:
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=days)
    tasks = []
    archive_dirs = [TASKS_ARCHIVE] + list(TASKS_ARCHIVE.glob("*/"))
    for d in archive_dirs:
        if not d.is_dir():
            continue
        for f in sorted(d.glob("task-*.txt")):
            content = f.read_text(encoding="utf-8", errors="replace")
            rec = _parse_task_file(content, f)
            if rec and rec.get("timestamp"):
                try:
                    ts = datetime.fromisoformat(rec["timestamp"].replace("Z", "+00:00"))
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts >= cutoff and rec.get("access_tier", "owner") == "owner":
                        tasks.append(rec)
                except (ValueError, AttributeError):
                    pass
    return tasks


def _parse_task_file(content: str, path: Path) -> dict | None:
    rec: dict = {}
    for line in content.splitlines():
        if ": " in line:
            key, _, val = line.partition(": ")
            rec[key.strip()] = val.strip()
        elif line.startswith("task:"):
            rec["task"] = line[5:].strip()
    if "task" not in rec:
        return None
    rec.setdefault("id", path.stem)
    return rec


def tokenize(text: str) -> list[str]:
    words = re.findall(r"[a-z]{3,}", text.lower())
    return [w for w in words if w not in STOPWORDS]


def tfidf_vector(tokens: list[str], idf: dict[str, float]) -> dict[str, float]:
    tf = Counter(tokens)
    total = len(tokens) or 1
    return {t: (tf[t] / total) * idf.get(t, 1.0) for t in tf}


def cosine_sim(a: dict[str, float], b: dict[str, float]) -> float:
    common = set(a) & set(b)
    if not common:
        return 0.0
    dot = sum(a[k] * b[k] for k in common)
    mag_a = math.sqrt(sum(v * v for v in a.values()))
    mag_b = math.sqrt(sum(v * v for v in b.values()))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)


def build_idf(task_tokens: list[list[str]]) -> dict[str, float]:
    n = len(task_tokens)
    df: Counter = Counter()
    for tokens in task_tokens:
        for t in set(tokens):
            df[t] += 1
    return {t: math.log(n / (1 + df[t])) for t in df}


def cluster_tasks(tasks: list[dict]) -> list[list[dict]]:
    """Greedy single-linkage clustering by cosine similarity."""
    all_tokens = [tokenize(t.get("task", "")) for t in tasks]
    idf = build_idf(all_tokens)
    vecs = [tfidf_vector(tok, idf) for tok in all_tokens]

    clusters: list[list[int]] = []
    assigned = [False] * len(tasks)

    for i in range(len(tasks)):
        if assigned[i]:
            continue
        cluster = [i]
        assigned[i] = True
        for j in range(i + 1, len(tasks)):
            if assigned[j]:
                continue
            sim = cosine_sim(vecs[i], vecs[j])
            if sim >= SIM_THRESHOLD:
                cluster.append(j)
                assigned[j] = True
        clusters.append(cluster)

    return [[tasks[i] for i in c] for c in clusters]


def candidate_slug(cluster: list[dict]) -> str:
    words = []
    for task in cluster[:3]:
        words.extend(tokenize(task.get("task", "")))
    common = Counter(words).most_common(3)
    base = "-".join(w for w, _ in common if w) or "workflow"
    h = hashlib.md5(base.encode()).hexdigest()[:4]
    return f"{base}-{h}"


def extract_prompt_template(cluster: list[dict]) -> str:
    """Derive a templated prompt from the cluster's most common structure."""
    samples = [t.get("task", "") for t in cluster[:4]]
    # Find the longest common prefix as a hint
    if len(samples) >= 2:
        common = samples[0]
        for s in samples[1:]:
            while not s.startswith(common) and common:
                common = common[: len(common) - 1]
        common = common.strip()
        if len(common) > 20:
            return f"{common} {{details}}"
    return samples[0] if samples else "{{task}}"


def already_proposed(slug: str) -> bool:
    skill_dir = LEARNED_DIR / slug
    return skill_dir.exists()


def propose_skill(cluster: list[dict]) -> str:
    slug = candidate_slug(cluster)
    if already_proposed(slug):
        return slug

    skill_dir = LEARNED_DIR / slug
    skill_dir.mkdir(parents=True, exist_ok=True)

    prompt_template = extract_prompt_template(cluster)
    sample_tasks = [t.get("task", "")[:120] for t in cluster[:4]]

    manifest = {
        "slug": slug,
        "source": "learned",
        "learned_from": len(cluster),
        "learned_at": datetime.now(tz=timezone.utc).isoformat(),
        "enabled": False,
        "status": "pending-review",
        "prompt_template": prompt_template,
        "sample_tasks": sample_tasks,
    }
    (skill_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    skill_md = f"""# {slug} (Learned Skill)

Auto-generated from {len(cluster)} similar workflow observations.

## What it does

{prompt_template}

## Sample invocations

{chr(10).join(f'- {s}' for s in sample_tasks)}

## Usage

This skill was detected automatically. Edit the prompt template above
before enabling. When satisfied, set `enabled: true` in manifest.json.
"""
    (skill_dir / "SKILL.md").write_text(skill_md)

    tools_ts = f'''import {{ work }} from "../../src/inline-tools.js";

export const tools = [
  {{
    name: "{slug}",
    description: "Learned workflow: {prompt_template[:80]}",
    input_schema: {{
      type: "object",
      properties: {{
        details: {{
          type: "string",
          description: "Specific details for this invocation",
        }},
      }},
    }},
    async execute({{ details }}: {{ details?: string }}) {{
      const prompt = `{prompt_template.replace("{details}", "${details || ''}")}`;
      return work.execute({{ task: prompt }}, null);
    }},
  }},
];
'''
    (skill_dir / "tools.ts").write_text(tools_ts)

    return slug


def queue_question(slug: str, cluster: list[dict]) -> None:
    today = datetime.now().strftime("%Y-%m-%d")
    sample = cluster[0].get("task", "")[:100]
    question = f"""
## {today}: Learned skill candidate — `{slug}`

Sutando detected {len(cluster)} similar tasks over the last {WINDOW_DAYS} days:

> {sample}...

A candidate skill bundle was created at `learned-skills/{slug}/`.

**Review and enable?**
- `yes` → set `enabled: true` in `learned-skills/{slug}/manifest.json`
- `refine` → edit `SKILL.md` + `manifest.json` before enabling
- `no` → delete `learned-skills/{slug}/`

"""
    existing = PENDING_Q.read_text() if PENDING_Q.exists() else "# Pending Questions\n"
    if slug not in existing:
        PENDING_Q.write_text(existing.rstrip() + "\n" + question)


def main() -> None:
    if not is_enabled():
        print("Learned skills detection is disabled (set state/learned-skills-enabled.sentinel to enable).")
        return

    tasks = load_recent_tasks()
    if len(tasks) < N_THRESHOLD:
        print(f"Not enough task history ({len(tasks)} tasks, need {N_THRESHOLD}).")
        return

    clusters = cluster_tasks(tasks)
    candidates = [c for c in clusters if len(c) >= N_THRESHOLD]

    if not candidates:
        print(f"No repeated patterns found (analyzed {len(tasks)} tasks in {len(clusters)} clusters).")
        return

    proposed = []
    for cluster in candidates:
        slug = propose_skill(cluster)
        if not (LEARNED_DIR / slug / "manifest.json").exists():
            continue
        manifest = json.loads((LEARNED_DIR / slug / "manifest.json").read_text())
        if manifest.get("status") == "pending-review":
            queue_question(slug, cluster)
            proposed.append(slug)

    if proposed:
        print(f"Proposed {len(proposed)} learned skill(s): {', '.join(proposed)}")
    else:
        print(f"Found {len(candidates)} candidate cluster(s) — all already proposed or reviewed.")


if __name__ == "__main__":
    main()
