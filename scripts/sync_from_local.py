#!/usr/bin/env python3
"""Compare local core MD files & installed skill against this kit repo,
flag personal hardcodes, and optionally sync sanitized updates back into the kit.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from pathlib import Path

KIT_DIR = Path(__file__).resolve().parent.parent
HOME_RAW = Path.home()
HOME = HOME_RAW.resolve()
HOME_VARIANTS = list(dict.fromkeys([str(HOME), str(HOME_RAW)]))

PERSONAL_PATTERNS = [
    (
        "abs_home_path",
        re.compile(
            r"(file://)?(" + "|".join(re.escape(h) for h in HOME_VARIANTS) + r")",
            re.I,
        ),
    ),
    ("abs_user_path", re.compile(r"(/Users/|/home/)[A-Za-z0-9._-]+", re.I)),
    (
        "personal_quota_note",
        re.compile(r"(grok-[0-9.]+.*?(耗尽|用完)|当前额度已?用完|暂不启用)", re.I),
    ),
]


def extract_section(text: str, heading_regex: str) -> str | None:
    """Extract either a marked block or a Markdown heading section matching heading_regex."""
    marker = re.search(
        r"<!--\s*BEGIN multi-agent-delegation\s*-->\s*\n(.*?)\n<!--\s*END multi-agent-delegation\s*-->",
        text,
        re.S,
    )
    if marker:
        return marker.group(1).strip() + "\n"

    lines = text.splitlines()
    start_idx = None
    start_level = None
    pat = re.compile(heading_regex)
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m and pat.search(m.group(2)):
            start_idx = i
            start_level = len(m.group(1))
            break
    if start_idx is None:
        return None

    end_idx = len(lines)
    for j in range(start_idx + 1, len(lines)):
        m = re.match(r"^(#{1,6})\s+", lines[j])
        if m and len(m.group(1)) <= start_level:
            end_idx = j
            break
    return "\n".join(lines[start_idx:end_idx]).strip() + "\n"


def scan_personal_lines(text: str) -> list[dict]:
    findings = []
    for idx, line in enumerate(text.splitlines(), start=1):
        for kind, pat in PERSONAL_PATTERNS:
            if pat.search(line):
                findings.append({"line": idx, "kind": kind, "text": line.strip()})
                break
    return findings


def sanitize_text(text: str) -> str:
    """Normalize local absolute home paths into portable $HOME / relative links."""
    for home_str in HOME_VARIANTS:
        text = text.replace(
            f"file://{home_str}/docs/delegation-best-practices.md",
            "./references/delegation-best-practices.md",
        )
        text = text.replace(f"file://{home_str}/", "~/")
        text = text.replace(f"{home_str}/", "~/")
        text = text.replace(home_str, "$HOME")
    return text


def safe_is_file(path: Path) -> bool | None:
    """Return True/False, or None if permission is denied by sandbox."""
    try:
        return path.is_file()
    except PermissionError:
        return None


def build_targets() -> list[dict]:
    docs_ref = HOME / "docs/delegation-best-practices.md"
    return [
        {
            "id": "skill",
            "label": "Installed SKILL.md -> kit SKILL.md",
            "local": HOME / ".agents/skills/multi-agent-delegation/SKILL.md",
            "kit": KIT_DIR / "skill/multi-agent-delegation/SKILL.md",
            "extract": None,
        },
        {
            "id": "script",
            "label": "Installed run_delegate.sh -> kit run_delegate.sh",
            "local": HOME / ".agents/skills/multi-agent-delegation/scripts/run_delegate.sh",
            "kit": KIT_DIR / "skill/multi-agent-delegation/scripts/run_delegate.sh",
            "extract": None,
        },
        {
            "id": "references",
            "label": "Local delegation-best-practices.md -> kit references",
            "local": (
                docs_ref
                if safe_is_file(docs_ref)
                else HOME / ".agents/skills/multi-agent-delegation/references/delegation-best-practices.md"
            ),
            "kit": KIT_DIR / "skill/multi-agent-delegation/references/delegation-best-practices.md",
            "extract": None,
        },
        {
            "id": "agents-rule",
            "label": "~/.gemini/AGENTS.md (delegation section) -> rules/AGENTS-snippet.md",
            "local": HOME / ".gemini/AGENTS.md",
            "kit": KIT_DIR / "rules/AGENTS-snippet.md",
            "extract": r"(多\s*Agent|委派)",
        },
        {
            "id": "claude-rule",
            "label": "~/.claude/CLAUDE.md (delegation section) -> rules/CLAUDE-snippet.md",
            "local": HOME / ".claude/CLAUDE.md",
            "kit": KIT_DIR / "rules/CLAUDE-snippet.md",
            "extract": r"(模型分工与委派|多\s*Agent)",
        },
    ]


def analyze_target(t: dict) -> dict:
    local_path: Path = t["local"]
    kit_path: Path = t["kit"]
    local_state = safe_is_file(local_path)
    res = {
        "id": t["id"],
        "label": t["label"],
        "local_path": str(local_path),
        "kit_path": str(kit_path),
        "local_exists": bool(local_state),
        "kit_exists": bool(safe_is_file(kit_path)),
        "status": "unknown",
        "personal_findings_raw": [],
        "personal_findings_after_sanitize": [],
        "diff": "",
        "sanitized_local": None,
    }
    if local_state is None:
        res["status"] = "permission_denied"
        return res
    if not local_state:
        res["status"] = "local_missing"
        return res

    raw_local = local_path.read_text(encoding="utf-8", errors="ignore")
    if t["extract"]:
        extracted = extract_section(raw_local, t["extract"])
        if extracted is None:
            res["status"] = "section_not_found"
            return res
        raw_local = extracted

    kit_text = kit_path.read_text(encoding="utf-8", errors="ignore") if kit_path.is_file() else ""
    sanitized = sanitize_text(raw_local)

    res["personal_findings_raw"] = scan_personal_lines(raw_local)
    res["personal_findings_after_sanitize"] = scan_personal_lines(sanitized)
    res["sanitized_local"] = sanitized

    if sanitized.strip() == kit_text.strip():
        res["status"] = "in_sync"
    else:
        res["status"] = "drifted"
        diff_lines = difflib.unified_diff(
            kit_text.splitlines(keepends=True),
            sanitized.splitlines(keepends=True),
            fromfile=f"kit/{kit_path.relative_to(KIT_DIR)}",
            tofile=f"local(sanitized)/{local_path.name}",
            n=2,
        )
        res["diff"] = "".join(diff_lines)
    return res


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect and sync local core MD / skill practices into multi-agent-delegation-kit."
    )
    parser.add_argument("--diff", action="store_true", help="Print unified diffs for drifted targets")
    parser.add_argument("--json", action="store_true", help="Output structured JSON report")
    parser.add_argument(
        "--only",
        default="",
        help="Comma-separated target IDs to inspect/apply: skill,script,references,agents-rule,claude-rule",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write sanitized local content into the kit repo for drifted targets",
    )
    parser.add_argument(
        "--allow-personal",
        action="store_true",
        help="Allow --apply even if personal quota notes remain after path sanitization",
    )
    args = parser.parse_args()

    only_set = {x.strip() for x in args.only.split(",") if x.strip()}
    targets = [t for t in build_targets() if not only_set or t["id"] in only_set]
    results = [analyze_target(t) for t in targets]

    if args.apply:
        applied = []
        blocked = []
        for r in results:
            if r["status"] != "drifted":
                continue
            if r["personal_findings_after_sanitize"] and not args.allow_personal:
                blocked.append(r["id"])
                continue
            Path(r["kit_path"]).write_text(r["sanitized_local"], encoding="utf-8")
            applied.append(r["id"])
        if not args.json:
            print(f"Applied: {', '.join(applied) if applied else 'none'}")
            if blocked:
                print(
                    f"Blocked (personal notes remain, review or pass --allow-personal): {', '.join(blocked)}",
                    file=sys.stderr,
                )
            return 1 if blocked else 0

    if args.json:
        clean = [{k: v for k, v in r.items() if k != "sanitized_local"} for r in results]
        print(json.dumps({"kit_dir": str(KIT_DIR), "targets": clean}, ensure_ascii=False, indent=2))
        return 0

    print(f"Kit directory: {KIT_DIR}")
    print("Local-to-kit drift & sanitization report:\n")
    for r in results:
        warn_count = len(r["personal_findings_after_sanitize"])
        raw_count = len(r["personal_findings_raw"])
        print(f"[{r['status'].upper():16}] ({r['id']}) {r['label']}")
        print(f"  local: {r['local_path']}")
        print(f"  kit:   {r['kit_path']}")
        if raw_count:
            print(
                f"  personal items detected: {raw_count} raw -> {warn_count} remaining after auto path sanitization"
            )
            for f in r["personal_findings_after_sanitize"]:
                print(f"    ! L{f['line']} [{f['kind']}]: {f['text']}")
        if args.diff and r["diff"]:
            print("  --- diff ---")
            for line in r["diff"].splitlines():
                print(f"  {line}")
        print("")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
