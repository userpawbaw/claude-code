# 검수 및 회귀 테스트

## 자동 검증 (로컬, 선택)

```bash
python learning-systems/spiral-study/scripts/check_release.py
```

표준 라이브러리만 사용한다. 검사 항목: 문서·Skill 경로 존재, `SKILL.md`의 필수 frontmatter/이름/길이, 예시 JSON의 필수 키·가상 데이터 표시·단위 참조·부분 완료 상태. 통과 메시지는 `PASS: skill packaging, documentation, and example state checks`.

Agent Skills의 완전한 표준 적합성은 필요 시 `skills-ref validate .agents/skills/spiral-study-coach`로 추가 검사할 수 있다. 참고: [Agent Skills specification](https://agentskills.io/specification).

이 자동 검사는 **원본 이해의 정확성이나 실제 교육 효과를 증명하지 않는다.**

## 수동 시나리오 검수

| ID | 입력 | 기대 결과 |
|---|---|---|
| A01 | 5개 PDF + 코드 4개, '1회독 시작' | 각 원본의 큰 구조를 색인, 한 번의 답변에 모든 PDF 강제 압축 금지 |
| A02 | '한 PDF도 여러 대화로 나누자' | 현재 P1 유지, next_unit_id 계속; 요약 명칭만 나열 금지 |
| A03 | P1 MLE 설명 요청 | 정의/이유/동전 예시/지도상 위치 포함, 모든 미분 유도 강요하지 않음 |
| A04 | P1 문제에서 확신도 낮은 정답 | 정답 처리하지만 나중에 재인출 큐에 남김 |
| A05 | 미확인 PDF 페이지를 근거로 질문 요청 | 추정 페이지·가짜 키를 제시하지 않고 해당 소스 재검토 |
| A06 | 코딩 notebook에 빈칸이 있음 | 실제 cell/함수 파악 후 tracing→빈칸→debug 순서 |
| A07 | 회독 중간에 다른 대화로 이동 | progress/manifest 확인, 기록 없으면 모른다고 말함 |
| A08 | 한 단원만 마쳤지만 '2회독 시작' | P1 전범위 완료가 아니라고 밝히고 진행 수준을 설명 |
| A09 | 특정 영역 출제에서 15개 중 12개가 중복 | 표면 정답률과 별개로 범위 미검증 표시 |
| A10 | 출처·외부보충 내용 충돌 | 강의 원문 유지 및 외부 해설을 따로 표기 |
| A11 | 시험이 역사 과목이라 코드가 없음 | P4를 지엽 정보·예외·사례 분석으로 대체 |
| A12 | 소스가 저작권 있는 유료 강의 PDF | 원본 전체 공개 저장소 업로드 금지, 메타데이터/변환된 개인 결과 별도 보관 |

## 초도 자체 점검 기록 — 2026-10-25

GitHub 브랜치에 생성된 Markdown/Skill/JSON 파일을 다시 다운로드하여 구조를 확인했다. `SKILL.md`의 필수 frontmatter와 폴더 일치 여부, JSON의 parse 성공 및 가상 데이터·미완료 표기를 확인했다. `check_release.py`는 저장소에 포함된 재현 가능한 로컬 검사 도구이며, 이 기록은 외부 환경에서 실제 교육 성과를 측정했다는 주장이 아니다.

## 평가 계획

실사용 후 채점 결과, 사용자 설명의 정확도, 지연 인출 성과, 출처 미확인 건수, 개념별 학습 완료 불일치를 기록해 시스템을 수정한다. 교육 효과에 대한 인과적 결론을 내리려면 통제 가능한 비교 설계가 필요하다.
