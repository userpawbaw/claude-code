#!/usr/bin/env python3
"""Lightweight local structural check for the portable spiral-study skill.

Uses only Python standard library. It validates packaging and the example
progress fixture; it does NOT judge pedagogy, factual accuracy, or full syllabus
coverage. Run from any working directory with Python 3.9+.
"""
from __future__ import annotations
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SKILL_DIR = ROOT / ".agents/skills/spiral-study-coach"
DOC_DIR = ROOT / "learning-systems/spiral-study"


def validate() -> list[str]:
    errors: list[str] = []
    skill = SKILL_DIR / "SKILL.md"
    example = SKILL_DIR / "assets/session-state.example.json"
    required = [
        skill, example,
        SKILL_DIR / "references/STATE_SCHEMA.md",
        *[DOC_DIR / name for name in
          ("README.md", "DESIGN.md", "PROTOCOL.md", "RESEARCH.md", "EXAMPLES.md")],
    ]
    for path in required:
        if not path.is_file():
            errors.append(f"missing: {path.relative_to(ROOT)}")
    if errors:
        return errors

    contents = skill.read_text(encoding="utf-8")
    match = re.match(r"\A---\n(.*?)\n---\n", contents, flags=re.S)
    if not match:
        errors.append("SKILL.md requires a YAML frontmatter block")
    else:
        header = match.group(1)
        metadata: dict[str, str] = {}
        for line in header.splitlines():
            if ":" not in line:
                errors.append(f"invalid metadata line: {line!r}")
                continue
            key, value = line.split(":", 1)
            metadata[key.strip()] = value.strip()
        name = metadata.get("name", "")
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
            errors.append("invalid skill name")
        if name != SKILL_DIR.name:
            errors.append("skill name must match its folder")
        desc = metadata.get("description", "")
        if not desc or len(desc) > 1024:
            errors.append("description must be nonempty, max 1024 characters")
        if len(name) > 64:
            errors.append("skill name exceeds 64 characters")
        if len(contents.splitlines()) > 500:
            errors.append("SKILL.md exceeds recommended 500 lines")

    try:
        data = json.loads(example.read_text(encoding="utf-8"))
    except (ValueError, OSError) as exc:
        return errors + [f"example JSON unreadable: {exc}"]
    required_keys = (
        "schema_version", "course_id", "is_fictional_data", "sources",
        "current_pass", "next_unit_id", "units", "question_attempts",
        "review_queue", "open_questions", "session_log",
        "full_pass_complete",
    )
    for key in required_keys:
        if key not in data:
            errors.append(f"example missing key: {key}")
    if data.get("is_fictional_data") is not True:
        errors.append("example data must be explicitly fictional")
    if data.get("full_pass_complete") is not False:
        errors.append("partial example must not claim a completed pass")
    units = data.get("units", [])
    ids = [u.get("unit_id") for u in units]
    if len(ids) != len(set(ids)):
        errors.append("duplicated unit_id")
    if data.get("next_unit_id") not in ids:
        errors.append("next_unit_id not found in units")
    source_ids = {s.get("source_id") for s in data.get("sources", [])}
    for unit in units:
        for ref in unit.get("source_refs", []):
            if ref.get("source_id") not in source_ids:
                errors.append(f"unit {unit.get('unit_id')} has unknown source")
    return errors


if __name__ == "__main__":
    failures = validate()
    if failures:
        for failure in failures:
            print("FAIL:", failure, file=sys.stderr)
        raise SystemExit(1)
    print("PASS: skill packaging, documentation, and example state checks")
