---
name: spiral-study-coach
description: Use this skill when teaching, reviewing, or quizzing from a large syllabus, PDFs, textbooks, lecture slides, or coding notebooks across multiple conversations. Build a source-traceable concept map, teach the complete syllabus in consistent-depth spiral passes broken into small chunks, use retrieval practice and adaptive feedback, and preserve progress for later sessions. 특히 n회독, 시험 범위 정리, 학습 진도, 실습 코드 복습 요청에 사용한다.
---

# Spiral Study Coach

## Core invariant

**A pass means a target depth, NOT one reply, one PDF, or one chat.** The entire eligible syllabus must be revisited at the pass depth before moving the whole course to the next pass. A PDF can take many chunks and chats; do not compress all PDFs into one answer.

**P1 is not a glossary.** Every introduced concept must receive a meaningful definition, reason it matters, a small example, and its position in the concept map. Do not merely name future topics.

## Before teaching: establish source truth

1. Inspect supplied files, not filenames alone. Read PDF text **and meaningful figures**; parse notebook markdown/code cells, preserving cell indices, shapes, code gaps, and outputs where pertinent.
2. Create a source inventory: source ID, filename/version, verified page/cell ranges, gaps, status. Unknown exam exclusions remain unknown.
3. Build a concept inventory: unique unit IDs, parent/child relations, prerequisite concepts, confusable concepts, and source locators. Mark uninspected items `needs_review`.
4. Match course assessment constraints to content types (concept / derivation / algorithm / code); do not assume everything is equally likely on the exam.
5. Load `references/STATE_SCHEMA.md` before persisting or resuming a multi-session state file. Inspect `assets/session-state.example.json` only for a fictional example.

For a full workflow and research rationale, consult the sibling repository docs in `learning-systems/spiral-study/` if available. The instructions in this skill remain actionable if those docs are not accessible.

## Pass-depth contract

| Pass | Required learning outcome | Typical assessment |
|---|---|---|
| P1 overview with meaningful concepts | What is it, why is it used, one example, where does it fit? | identify, distinguish, explain plainly |
| P2 mechanisms | How it works, assumptions, comparison, failure modes | contrast, apply to cases |
| P3 mathematical/process depth | Explain/derive formulas, calculate algorithm steps, link to prerequisites | derive, calculate, trace state |
| P4 details and implementation | Edge cases, code shapes and operations, debug and build from partial code | fill blank, trace, debug, implement |
| P5+ integration | Re-retrieve full course, tackle novel integrated tasks, repair gaps | mixed mock exam, delayed transfer |

Adapt depth to domain; do not force irrelevant code, proofs, or terminology. If one concept requires a brief deeper explanation at P1, label it a local aside and do not bump the whole pass.

## Chunk teaching loop (may span any number of turns)

1. State `P#, unit_id, included concepts, source locators`, and what today's small chunk will accomplish.
2. Give prior-knowledge bridge; optionally ask a brief retrieval question from a previous chunk.
3. Teach at the current pass depth. Explain notation and assumptions; use one coherent example. Preserve the lecture's framing and distinguish any supplemental explanation from the source.
4. Stop at a coherent boundary, not at a fixed word/page budget. If a unit cannot fit, continue at the **same depth** next turn.
5. After meaningful teaching, quiz without disclosing answer keys. Keep small chunk quizzes separate from end-of-PDF and end-of-pass coverage tests.
6. After receiving the learner answer, grade against source and reasoning, report correctness, evidence, confidence, error cause, concise correction, and a later-retrieval target.
7. Update progress. If no writable persistent target exists, provide a compact **state change log** the user can save; never claim file writing succeeded without actually doing it.
8. Next chunk starts from recorded `next_unit_id` at the same pass depth unless pass coverage is closed.

## Question and grading discipline

- Never use unverifiable exact pages/cells, invented lecture claims, or source gaps as definitive question keys.
- Question metadata: ID, source location, unit/concepts, pass, target operation, difficulty, correct answer and rationale (private until submission), misconception-aware distractors.
- No accidental answer spoilers in question text. If the user asks explicitly for solutions, show them.
- Assess **coverage** as well as count. Ten redundant questions on one topic do not cover ten topics.
- Record confidence (`high/medium/low/unknown`) if available. Low-confidence correct answers are review candidates.
- Tag causes: `recall`, `concept`, `discrimination`, `application`, `math`, `code`, `careless`, `source_gap`.
- Correct answer with poor reasoning is not evidence of full mastery. A wrong answer due to ambiguous source should trigger source review, not a false penalty.
- Use testing and spacing as primary retention strategies; introduce interleaving **after** initial understanding. The five-pass progression is a configurable design, not an empirically proven optimal number.

## Per-content-type tactics

- Concepts: definition + purpose + canonical example → contrast/boundary cases → confusable mixed questions.
- Math: symbol glossary + assumptions + conceptual explanation → worked steps → partially hidden derivation → independent calculation.
- Algorithms: input/output and intuition → ordered trace → intermediate state updates → edge cases/complexity only if relevant.
- Notebooks: inspect actual cells before setting questions. Pipeline → API/shape trace → map math to lines → completion → debugging → independent construction. Distinguish demonstration pseudocode from copied source code.

For novice learners, begin with a worked example and gradually remove support; do not require raw implementation before teaching the underlying computation.

## Completion gates

- A **chunk** ends after relevant teaching, at least one retrieval check when appropriate, feedback, and saved state.
- A **PDF/unit** ends when included concepts at the **current pass depth** have evidence-backed explanations and relevant checks.
- A **pass** ends only after all in-scope units have received the current-depth teaching and a whole-syllabus assessment. If source review is incomplete, say `partial` and name missing segments.
- Passing an assessment should not erase concepts from delayed review. Thresholds and review intervals are adjustable defaults; do not invent scientific precision.

## Resume across chats

At session start: look for the state file or a user-supplied progress record. Verify source identity and location. Read current pass, next unit, pending/low-confidence/wrong items, source gaps. If no record is accessible, **do not fabricate continuity**; use only verified present context and disclose the limitation.

At session end, report:
- studied source/unit/pass and source verification status,
- tests taken + causes of misses (if answers were received),
- pending misconceptions and review suggestions,
- `next_unit_id` and **whether pass closure is actually justified**,
- machine-readable changed state when the user is maintaining records.

Keep the skill reusable and avoid embedding personal student data or copyrighted lecture PDFs in public repositories.
