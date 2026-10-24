# Portable study state — v1.0

## Principle

A conversation does not guarantee memory of previous conversations, file availability, or persistence. A **user-controlled state file** is the canonical continuity mechanism. Store this file outside publicly shared Git repositories unless explicitly intended.

## Recommended files for an actual course

```text
course/
  source-manifest.json         # filename, hash, accessible locator, verified ranges
  concept-inventory.json       # all concept IDs, hierarchy, source references, status
  progress.json                # pass/unit pointers, question attempts, review queue
  question-bank.jsonl          # optionally private: items including answer keys
  session-log.md               # human-readable decisions/open issues
```

Small courses may use one combined `progress.json`; large courses should split files to avoid repeated context loading. Update files atomically or append versioned deltas.

## Combined format (example is in assets/)

Top-level fields:

| Field | Type | Purpose |
|---|---|---|
| `schema_version` | string | e.g. `1.0.0` |
| `course_id` | string | opaque slug, no personal identifiers |
| `is_fictional_data` | boolean | true only for demonstration/test fixture |
| `exam_scope` | object | included, excluded with evidence, unknown, assessment format |
| `sources` | array | source_id, filename, sha256/null, access, coverage, locator scheme, verified ranges |
| `current_pass` | integer | 1-based depth level |
| `next_unit_id` | string/null | unit to teach when resumed |
| `units` | array | unit_id, title, parent_id, source refs, `status_by_pass`, dependencies |
| `question_attempts` | array | question_id, concept/unit IDs, pass, correctness, confidence, error_tags, date/time optional |
| `review_queue` | array | concept_id, reason, earliest_due nullable, priority |
| `open_questions` | array | unresolved item, source, resolution action |
| `session_log` | array | session marker, covered units, next action, notes |
| `full_pass_complete` | boolean | must be true only when all eligible units verified/assessed at this depth |

Source refs use `{source_id, locator, verification}` and a stable convention such as `p.7` (PDF 1-based) or `cell[5]` (ipynb 0-based). A citation to a page not inspected is `verification: needs_review`, never verified.

## Controlled status values

- `source.coverage`: `uninspected`, `partial`, `verified`.
- `source.access`: `available`, `unavailable`, `not_attached`.
- `unit.status_by_pass.Pn`: `not_started`, `teaching`, `taught`, `assessed`, `revisit`, `excluded_with_evidence`.
- `question_attempt.correctness`: `correct`, `incorrect`, `partial`, `ungraded`.
- `confidence`: `high`, `medium`, `low`, `unknown`.
- `error_tags`: `recall`, `concept`, `discrimination`, `application`, `math`, `code`, `careless`, `source_gap`.

## Invariants for machine/human validation

1. Every `unit_id` is unique; every `next_unit_id` references a known non-excluded unit.
2. Every non-excluded unit has source references; unverified source ranges do not imply pass completion.
3. Any `assessed` unit must have at least one actual completed assessment record for that pass (unless explicitly marked manual override with justification).
4. `full_pass_complete=true` only when all in-scope units are at least `assessed` in that pass, source coverage is sufficient, and a cumulative pass assessment exists.
5. Never store correctness before an answer is actually received.
6. Updating a source revision/hash invalidates affected verified locators/questions until rechecked.
7. Transition from pass P to P+1 is a separate logged decision; it must not happen because a message, day, or single PDF ended.
8. Preserve failed and low-confidence items for later retrieval. Do not rewrite historical attempts when regrading: append a corrective event.
9. Unknown/unavailable data should be null/unknown, not a plausible-looking invented value.
10. Personal identifiers, copyrighted PDFs, or answer keys for a current examination should not be committed to a public shared repository.

## Status-delta format when persistent writes are impossible

```json
{
  "event": "session_progress_delta",
  "course_id": "sample",
  "current_pass": 1,
  "completed_unit_ids": ["U01-A"],
  "next_unit_id": "U01-B",
  "questions_answered": ["Q-P1-001"],
  "review_added": ["U01-A"],
  "open_questions_added": [],
  "persisted": false
}
```

`persisted=false` means the agent has **shown** data but not saved it to the durable store. Never say the system 'automatically remembered' it.
