# Part 3 — Bootstrap Agent

> **이 문서의 위치**
> 7부작 중 3부. Part 1(인터뷰)·Part 2(문서화)를 실제로 수행하는 **에이전트**를 Claude Code 안에 어떻게 구성하는지 정의한다.
> 본문은 도메인 중립 + Claude Code 설정 예시(일반형). 이번 SRCNN 사례는 말미 **[사례 부록]**.

---

## 1. 목표

**RTL(구현물) 생성기가 아니라 "설계 준비 에이전트"를 만든다.**

대부분의 사람은 코딩 에이전트를 "코드 뱉는 기계"로 쓴다. 이 매뉴얼의 핵심 주장은, 좋은 결과의 80%는 코드 생성이 아니라 **그 앞단(설계 확정)과 뒷단(검증)** 에서 나온다는 것이다. Bootstrap Agent는 앞단을 담당한다.

이 에이전트의 출력은 코드가 아니라:
- 채워진 Decision DB (Part 1)
- ADR + 생성 문서 3종 (Part 2)
- "이제 구현해도 된다"는 게이트 통과 신호

---

## 2. 역할

1. **인터뷰** — 6영역(Mission/Constraints/Algorithm/Dataflow/Implementation/Verification)을 질문으로 채운다.
2. **Decision DB 생성** — 확정 사항을 `design/decisions/`에 떨군다.
3. **ADR 생성** — 대안이 있었던 결정은 `docs/adrs/`에 맥락과 함께 기록.
4. **문서 생성** — architecture / module_contracts / verification_plan.
5. **프로젝트 로그 관리** — `logs/`에 append-only로 진행 누적.

---

## 3. 상태 관리

6영역 각각이 `Complete` / `Incomplete`를 가진다. 에이전트는 매 턴 이 상태를 추적하고, 어디가 비었는지 사용자에게 보여준다.

```
[Bootstrap State]
  Mission        : Complete
  Constraints    : Incomplete  ← 자원 예산 미확정
  Algorithm      : Incomplete  ← 활성함수 유무 미확정
  Dataflow       : Complete
  Implementation : Complete
  Verification   : Complete
```

상태는 추상이 아니라 파일로 존재해야 한다. 예: `design/state.md` 또는 각 영역 디렉토리의 존재/완결 여부로 판정.

---

## 4. RTL 생성 게이트 (핵심)

**모든 6영역이 Complete이고 `unresolved_questions/`가 비었을 때만 RTL Generation Mode 진입.**

이 게이트는 에이전트의 시스템 프롬프트(아래 CLAUDE.md)에 hard rule로 박는다. "사용자가 코드를 빨리 달라고 해도, 게이트 미통과 시 먼저 누락 영역을 질문한다."

이게 실전에서 가장 자주 무너지는 규칙이다. 사용자는 늘 코드를 먼저 원한다. 하지만 게이트를 양보하면 Part 1의 [사례 부록]에서 본 "LUT 폭증을 다 만든 뒤 발견" 같은 일이 반복된다.

---

## 5. Claude Code 구성 (일반형 예시)

### 5.1 CLAUDE.md — 에이전트의 헌법

CLAUDE.md는 매 세션 자동으로 컨텍스트에 들어가는 프로젝트 규칙 파일이다. 리포지토리 루트에 둔다. Bootstrap Agent의 행동 규칙을 여기 박는다.

```markdown
# CLAUDE.md

## Project
<프로젝트 한 줄 정의>

## Operating Mode
이 리포는 "설계 우선" 워크플로를 따른다. 두 모드가 있다:
- DESIGN MODE (기본): 인터뷰/문서화만 수행. 구현 코드 생성 금지.
- BUILD MODE: 6영역 게이트 통과 시에만 진입.

## Hard Rules
1. 세션 시작 시 docs/ 와 design/state.md 를 먼저 읽는다.
2. 6영역 중 Incomplete가 하나라도 있으면 BUILD MODE 진입 금지.
   사용자가 코드를 요청해도, 먼저 누락 영역을 한두 개 질문으로 채운다.
3. 추측 금지. 모르면 design/assumptions/ 에 가정으로 분리하고 사용자 확인을 받는다.
4. 확정 사항은 그 턴에 즉시 design/decisions/ 에 기록한다.
5. 대안이 있었던 결정은 docs/adrs/ 에 ADR로 남긴다.

## Context Recovery
세션이 끊기면 logs/ 의 마지막 항목과 docs/ 를 읽고 이어간다.
```

> **운용 팁**: 긴 세션에서는 시스템 수준 지시가 점차 후순위로 밀리는 "context drift"가 생긴다. 그래서 hard rule은 짧고 강하게, 그리고 핵심 규칙은 슬래시 커맨드로도 재주입할 수 있게 한다(5.2).

### 5.2 슬래시 커맨드 — 반복 작업 매크로

권장 형식은 `.claude/skills/<name>/SKILL.md`다(레거시 `.claude/commands/*.md`도 동작하지만 skill 형식이 자동 호출까지 지원). 같은 이름이면 skill이 우선한다.

> **안티패턴 경계 (헤비유저 최신 합의 — 반드시 읽을 것)**
> 2026년 현재 가장 강한 경고 중 하나: **"복잡한 커스텀 슬래시 커맨드가 길게 늘어서면 그 자체가 안티패턴이다."** 핵심은 "거의 아무거나 입력해도 유용한 결과가 나오는 것"이지, 모든 동작을 커맨드로 박제하는 게 아니다. 또한 단순한 제어 루프가 다중 에이전트 시스템을 이긴다는 게 반복 검증된 결론이다.
> 그리고 2026년의 harness는 이미 많은 걸 자동화한다 — plan mode가 설계 단계를, 자동 컴팩션이 컨텍스트를, Agent 도구가 격리 병렬 탐색을 처리한다. 따라서 **"이 커맨드가 harness 기본기능이나 자연어로 이미 되는 일을 중복하는가?"** 를 항상 자문하라. 답이 예면 만들지 마라.
>
> **그러므로 이 매뉴얼의 커맨드는 "필수 최소"만 둔다.** 아래 예시는 전부 만들라는 뜻이 아니라, *프로세스 규율을 강제할 한두 개*만 고르라는 것이다. 권장 최소 세트: `gate-check`(BUILD 게이트 강제) 1개. 나머지(interview/investigate 등)는 자연어로 충분하면 만들지 않는다.

Bootstrap용 커맨드 예 (선택):

```markdown
<!-- .claude/skills/interview/SKILL.md -->
---
name: interview
description: 설계 6영역 중 Incomplete 영역을 골라 인터뷰를 진행한다
---
design/state.md 를 읽어 Incomplete 영역을 찾고,
그 영역에 대해 한 번에 1~2개의 객관식 질문을 한다.
답을 받으면 design/decisions/ 에 DEC 파일로 기록하고 state를 갱신한다.
```

```markdown
<!-- .claude/skills/gate-check/SKILL.md -->
---
name: gate-check
description: BUILD MODE 진입 가능 여부를 판정한다
---
6영역 상태와 unresolved_questions/ 를 점검해
통과/미통과와 막고 있는 항목을 보고한다. 미통과면 BUILD 진입을 거부한다.
```

### 5.3 Subagent — 컨텍스트 격리

subagent는 `.claude/agents/`에 둔다. 핵심 가치는 병렬성이 아니라 **컨텍스트 격리**다. 한 대화에서 인터뷰·문서화·검증을 다 하면 맥락이 서로 오염된다(검증 논의가 설계 결정을 흔드는 식).

Bootstrap 단계에서는 보통 subagent까지 갈 필요는 없다. 다만 "문서 생성"처럼 본 세션 컨텍스트를 더럽히지 않고 끝내고 싶은 작업은 subagent로 분리할 수 있다.

> subagent는 공짜가 아니다. 컨텍스트 격리가 실제로 필요할 때만 쓴다(긴 작업 중 메인 세션을 깨끗이 유지, 샌드박스 도구 호출, 병렬 리서치 등).

---

## 6. 진입/종료 흐름

```
사용자: /interview
  → 에이전트가 Incomplete 영역 질문
  → 사용자 답변 → DEC 기록 → state 갱신
  (반복)
사용자: /gate-check
  → 미통과: 막는 항목 보고, DESIGN MODE 유지
  → 통과: BUILD MODE 허용 (Part 4 검증 에이전트로 연결)
```

---

## [사례 부록] SRCNN 프로젝트에 Bootstrap Agent가 있었다면

> 재사용 시 교체.

이번 프로젝트는 Bootstrap Agent 없이 진행됐다. 그 결과 나타난 증상들을, 만약 이 에이전트가 있었다면 어떻게 막았을지로 정리한다.

- **증상**: 단일 line_buffer를 다 만든 뒤 LUT ~10000 발견 → 정적 윈도우로 재설계.
  **Bootstrap이 있었다면**: Constraints 영역에서 "4채널 병렬, 채널당 LUT 예산"이 DEC로 강제됐을 것이고, gate-check가 자원 예산 미확정을 이유로 BUILD를 막았을 것이다.

- **증상**: "누적이 15bit 안 넘는다"가 한동안 미검증 가정.
  **Bootstrap이 있었다면**: `assumptions/`에 분리되어 사용자 확인 또는 레퍼런스 계산을 강제, decision 승격 전엔 코드가 의존 못 하게 했을 것이다.

- **증상**: ReLU 유무가 지금도 PENDING인데 conv-only로 진행 중.
  **Bootstrap이 있었다면**: Algorithm 영역이 Incomplete로 남아 gate-check를 통과 못 했을 것이다. (현실적으로는 "conv-only로 확정"이라는 DEC를 받고 통과시키는 게 맞다 — 핵심은 *명시적 결정*을 강제한다는 점.)

- **증상**: 컨텍스트가 끊겨 진행 내역 유실, prefetch=2/1 혼선.
  **Bootstrap이 있었다면**: 매 결정이 즉시 DEC/ADR로 기록되고 logs/가 append-only라, 재개 시 prefetch는 ADR 한 장으로 즉시 복원됐을 것이다.

요컨대 이 프로젝트의 모든 "막힘"은 Bootstrap 단계의 부재에서 추적된다 — 이게 이 매뉴얼을 만드는 동기 그 자체다.
