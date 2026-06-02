# AI-Assisted Development Operating Manual

> Claude Code로 **설계 → 문서화 → 구현 → 검증 → 학습**의 전 주기를 규율 있게 돌리기 위한 운용 매뉴얼.
> 대원칙: **실행 전에 모호성을 붕괴시키고, 실행 후에 증거로 검증한다.**

---

## 이 매뉴얼을 처음 여는 사람에게

**먼저 [Part 0](Part0_Overview_and_Session_Discipline.md)을 읽으세요.** 전체 지도와, 모든 단계에 공통으로 적용되는 컨텍스트·세션 규율이 거기 있습니다.

근거: 한 결정의 정답률이 80%여도 결정이 20개면 전부 맞을 확률은 약 1%다. 이 매뉴얼의 모든 단계는 그 곱셈을 끊기 위한 구조다.

---

## 문서 구성 (7부작)

| 부 | 문서 | 역할 |
|----|------|------|
| 0 | [Part 0 — 개요 & 세션 운용](Part0_Overview_and_Session_Discipline.md) | 진입점. 7부작 지도 + 컨텍스트 60%룰·세션 규율 |
| 1 | [Part 1 — 설계 인터뷰 & Decision DB](Part1_Design_Interview_and_Decision_DB.md) | 실행 전 모호성 붕괴 (6영역 인터뷰) |
| 2 | [Part 2 — 문서화 & ADR](Part2_Documentation_and_ADR.md) | 설계 의도를 복원 가능하게 (ADR + 문서 3종) |
| 3 | [Part 3 — Bootstrap Agent](Part3_Bootstrap_Agent.md) | 1·2를 수행 + BUILD 게이트 (CLAUDE.md) |
| 6 | [Part 6 — Plan → Tasks → Implement](Part6_Plan_Tasks_Implement.md) | 검증된 설계를 의존성 순서로 단계 구현 |
| 4 | [Part 4 — Verification Agent](Part4_Verification_Agent.md) | 구현이 설계와 맞는지 가설 기반 증명 (8단계) |
| 5 | [Part 5 — Knowledge Graph & Learning](Part5_Knowledge_Graph_and_Learning.md) | 산출물 연결 + 반복 패턴 학습 환류 |

**실행 순서**: `0 → 1 → 2 → [3 게이트] → 6 → 4 → 5` (번호 순서 ≠ 실행 순서; Part 4·5는 상위 계층이라 뒤 번호)

```
Part 0 (세션 준비)
  └─ Part 1 인터뷰 → Part 2 문서화 → [Part 3 BUILD 게이트]
                                          └─ Part 6 Plan→Tasks→Implement
                                                └─ Part 4 검증(8단계)
                                                      └─ Part 5 그래프 + 패턴 학습
                                                            └─(PAT 환류)→ 다음 프로젝트 Part 1
```

---

## 디렉토리 레이아웃 (리포 루트)

```
.
├── CLAUDE.md                 # 에이전트 헌법 (Part 3 템플릿)
├── docs/manual/              # 이 매뉴얼 7개 문서 (Part 0~6)
├── design/
│   ├── decisions/            # DEC-* 확정 결정
│   ├── assumptions/          # 미확인 가정
│   ├── unresolved_questions/ # 열린 질문
│   └── state.md              # 6영역 Complete/Incomplete 상태
├── docs/
│   ├── adrs/                 # ADR-*
│   ├── architecture.md
│   ├── module_contracts.md
│   └── verification_plan.md
├── plan.md  tasks.md         # Part 6 산출물
├── verification/
│   ├── investigations/       # INV-*
│   ├── bugs/                 # BUG-*
│   └── regressions/          # REG-*
├── knowledge/
│   ├── index.md              # 지식 그래프
│   └── patterns/             # PAT-* 실패 패턴
└── logs/                     # append-only 진행 로그
```

---

## 핵심 원칙 5줄 요약

1. **설계 완료 전 구현 금지.** 6영역이 Complete가 아니면 BUILD 게이트를 통과시키지 마라. (Part 1·3)
2. **컨텍스트 60%를 넘기지 마라.** 넘기기 전에 파일로 덤프하고 `/clear` 후 재개. `/compact` 의존 금지. (Part 0)
3. **태스크는 작게, 의존성 순서로, 검증을 붙여서.** 한 태스크 = 한 세션 60% 안에서 구현+검증+커밋. (Part 6)
4. **느낌으로 고치지 마라.** 증상→가설→실험→증거로 좁혀라. 모든 진술에 Fact/Hypothesis/Proven 라벨. (Part 4)
5. **커스텀 자산은 필수 최소만.** harness가 이미 하는 일을 커맨드로 중복하지 마라. (Part 0·3)

---

## 도메인 적용 노트

- 본문은 **도메인 중립**. 도메인 색깔(RTL/SRCNN 등)은 각 문서 말미 **[사례 부록]** 에만 있다.
- **다른 주제로 시작하면**: 본문·프로세스·세션 규율·CLAUDE.md 골격은 그대로 재사용. 교체할 것은 (1) 각 문서의 사례 부록, (2) Part 5의 Failure Pattern 카탈로그(도메인 의존), (3) CLAUDE.md의 프로젝트 정의 한 줄. 나머지는 인터뷰(Part 1)를 통해 Claude Code가 너와 대화하며 새로 채운다.
- 무게 조절: 하드웨어/RTL은 Constraints·검증을 엄격하게, 일반 소프트웨어는 가볍게. (Part 0 §4)
