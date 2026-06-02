# Part 2 — Documentation & ADR System

> **이 문서의 위치**
> 7부작 중 2부. Part 1에서 수집한 결정(decision)을, 미래의 누구든(다른 세션의 AI 포함) 설계 의도를 복원할 수 있는 문서로 변환하는 단계를 정의한다.
> 본문은 도메인 중립. 이번 SRCNN 사례는 말미 **[사례 부록]** 에 격리.

---

## 1. 목표

설계 의도를 **미래에도 복원 가능하게** 만든다.

이게 왜 필요한지는 이 프로젝트 자체가 증명했다. 긴 대화가 컨텍스트 한도에 막혀 끊기면, 그때까지의 결정·검증 내역이 사실상 유실된다. 코드는 남아도 "왜 그렇게 했는지"가 사라지면, 다음 세션의 AI는 같은 분석을 처음부터 다시 한다(그리고 종종 다른 결론을 낸다).

문서화의 핵심 원칙: **문서는 설계 결정으로부터 생성되어야 한다.** 코드에서 사후적으로 추출하는 게 아니라, Part 1의 decision/ADR이 1차 소스이고 문서는 그 파생물이다.

---

## 2. 디렉토리 구조

```
docs/
├── decisions/            # Part 1에서 넘어온 확정 결정 (DEC-*)
├── adrs/                 # Architecture Decision Records (ADR-*)
├── architecture.md       # 시스템 구조 (생성물)
├── module_contracts.md   # 모듈 인터페이스 계약 (생성물)
├── verification_plan.md  # 검증 계획 (생성물)
└── logs/                 # 세션 로그 / 진행 기록
```

`decisions/`(무엇을 정했나)와 `adrs/`(왜·어떤 대안 대신 정했나)를 나누는 이유: decision은 단편적 사실이고, ADR은 그 사실이 선택된 **맥락과 기각된 대안**을 담는다. 버그 추적 시 "왜 이 구조지?"에 답하는 건 ADR이다.

---

## 3. ADR 양식

```markdown
# ADR-005: line_buffer를 동적 인덱싱에서 정적 윈도우로 변경

## Status
Accepted (2026-06-01)

## Context
3×152 라인을 FF에 받고 3×3 출력 윈도우를 동적 인덱싱하는 구조는
MUX 소모가 과대했다. 단일 채널 합성에서 LUT ~10000.
4채널 병렬화 시 감당 불가.

## Decision
윈도우를 LSB에 고정하고 shift로 데이터를 흘려보낸다.
r_line 시프트 FF는 SRL32로 최적화.

## Consequences
- (+) LUT 약 1/20 수준으로 감소
- (+) 4채널 병렬화 가능
- (−) valid 타이밍 재정의 필요: 3행 3열째 입력부터 152열까지만 유효
- (−) FSM 상태 단순화 동반 (6상태 → 4상태, S_I_STREAM 통합)

## Alternatives Considered
1. 동적 인덱싱 유지 + 채널 수 축소 → 알고리즘 요구 위배, 기각
2. BRAM 기반 line buffer → read latency가 valid 파이프와 안 맞음, 기각
```

ADR의 핵심은 **Alternatives Considered**다. 이게 없으면 다음 세션이 이미 기각된 대안을 다시 제안한다.

---

## 4. 생성 문서 3종

### 4.1 architecture.md
- 시스템 블록 다이어그램(텍스트/ASCII 가능), 레이어별 데이터패스, 모듈 간 연결.
- "데이터가 어디서 와서 어디로 가는가"를 한눈에.

### 4.2 module_contracts.md
- 각 모듈의 포트 표 + valid/timing 규약 + 비트폭.
- **이게 가장 중요한 생성물.** 모듈 경계의 계약이 명문화되어 있으면, 모듈을 독립적으로 검증·교체할 수 있다.

계약 항목 예:
```markdown
## pe_group
| port | dir | width | meaning |
|------|-----|-------|---------|
| i_line_valid | in | 1 | line_buffer o_line_valid |
| i_line_data  | in | 144 | 3×3 window (16b×9) |
| i_weight     | in | 16 (signed) | 브로드캐스트 weight |
| i_wen        | in | 9 | PE 슬롯 latch enable (one-hot) |
| o_valid      | out | 1 | i_line_valid 기준 3clk 지연 |
| o_partial    | out | 21 (signed) | 공간 9-tap 합 |

**Timing contract**: i_line_valid → (PE 1clk) → (adder stage1 1clk) → (adder total 1clk) = o_valid 3clk 지연.
모든 done/valid 패스스루 신호는 이 3단에 정렬되어야 한다.
```

### 4.3 verification_plan.md
- 단계별 검증 순서, 각 단계의 golden, pass 기준.
- Part 4(검증 에이전트)의 입력이 된다.

---

## 5. 문서 생성 규칙 (Claude Code 운용)

- **decision/ADR이 바뀌면 생성 문서를 갱신한다.** 역방향(문서를 직접 고치고 ADR 안 고침)은 금지. 단일 진실 출처는 항상 decision/ADR.
- **CLAUDE.md에서 이 디렉토리를 참조하게 한다.** 세션 시작 시 AI가 `docs/`를 먼저 읽도록 CLAUDE.md에 명시 → 컨텍스트 복원 자동화.
- **로그는 append-only.** `logs/`는 덮어쓰지 않고 누적. 끊긴 세션을 이어받을 때 마지막 로그가 진입점.

---

## [사례 부록] SRCNN 프로젝트의 문서화 실태

> 재사용 시 교체.

이 프로젝트에는 이미 `verification_notes.md`라는 훌륭한 생성 문서가 있었다. 가중치 BRAM 32word 레이아웃, 레이어별 FSM 파라미터 표, 데이터패스 요약, 수행한 검증 7건, 미해결 항목(PENDING) 5건이 정리되어 있었다.

**잘된 점**: 이 노트 덕분에 컨텍스트가 끊긴 뒤에도 "어디까지 했는지"를 상당 부분 복원할 수 있었다. 특히 PENDING 섹션(7.1 URAM→FIFO 타이밍, 7.5 ReLU 등)이 명시적이라 다음 작업 진입점이 명확했다.

**부족했던 점**: ADR이 없었다. 예를 들어 line_buffer를 정적 윈도우로 바꾼 결정은 코드(`line_buffer_improved.v`)와 주석엔 있지만, "왜 동적을 버렸고 어떤 대안을 기각했는지"가 독립 문서로 없었다. 그래서 복구 과정에서 AI가 한때 "prefetch=2가 견고"라고 했다가 실제 채택안(prefetch=1)과 어긋나는 일이 생겼다 — 결정의 *맥락*이 문서화되지 않아 재구성이 흔들린 사례.

**module_contracts의 가치**: `pe_group`에 `i_line_done`/`o_pe_done` 포트를 추가할 때, "o_valid와 동일하게 3단 지연"이라는 타이밍 계약이 명확했기 때문에 done 패스스루를 정확히 `i_line_done → done_d0 → done_d1 → o_pe_done`으로 구현할 수 있었다. 계약이 없었으면 몇 단 지연인지 추측해야 했다.
