---
name: feature-dev
description: 기능 추가나 수정 요청을 분석, 구현, 검증, 리뷰 순서로 서브에이전트에 나눠 처리하고 단계별 결과를 .work/에 남긴다. 훅이 단계 순서와 조기 종료를 검사한다
argument-hint: <구현할 기능 설명>
disable-model-invocation: true
allowed-tools: Bash(bash ~/.claude/skills/feature-dev/guard.sh *)
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'bash "$HOME/.claude/skills/feature-dev/guard.sh" hook'
  UserPromptSubmit:
    - hooks:
        - type: command
          command: 'bash "$HOME/.claude/skills/feature-dev/guard.sh" hook'
  PreToolUse:
    - matcher: "Agent"
      hooks:
        - type: command
          command: 'bash "$HOME/.claude/skills/feature-dev/guard.sh" hook'
  PostToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: 'bash "$HOME/.claude/skills/feature-dev/guard.sh" hook'
  PostToolUseFailure:
    - matcher: "Bash"
      hooks:
        - type: command
          command: 'bash "$HOME/.claude/skills/feature-dev/guard.sh" hook'
---

# 기능 개발 절차

요청 내용: $ARGUMENTS

가드 초기화: !`bash ~/.claude/skills/feature-dev/guard.sh init ${CLAUDE_SESSION_ID}`

아래 순서를 건너뛰지 않는다. 메인 세션은 코드를 직접 수정하지 않고,
단계 조율, 결과 파일 저장, 검증 실행, 리뷰 지적 판단만 한다.

## 가드 규칙 (훅이 자동 검사)

- 상태 변경 명령. 상태 JSON을 직접 편집하지 않는다.
  - `bash ~/.claude/skills/feature-dev/guard.sh workdir ${CLAUDE_SESSION_ID} <작업 폴더>`
  - `bash ~/.claude/skills/feature-dev/guard.sh status ${CLAUDE_SESSION_ID} <running|waiting_user|cancelled>`
- **사용자 입력이 필요해 멈출 때는 반드시 먼저 `status ... waiting_user`를 실행한다.** 사용자가 답하면 훅이 자동으로 running으로 되돌린다.
- 사용자가 작업 중단을 요청하면 `status ... cancelled`를 실행한다.
- 훅이 차단하면 차단 이유를 따르고, 우회하려고 결과 파일이나 상태를 조작하지 않는다.
- `03-verification.md`는 훅이 기록한다. 메인 세션은 이 파일을 쓰거나 고치지 않는다.

## 0단계: 작업 폴더 준비

- 작업 폴더를 `.work/<YYYY-MM-DD>-<영문-kebab-작업명>/`으로 정한다. (예: `.work/2026-11-18-order-partial-cancel`)
  - 날짜는 오늘, 작업명은 요청을 요약한 영문 소문자 2~5단어. 같은 이름이 있으면 끝에 `-2`, `-3`을 붙인다.
- `workdir` 명령으로 등록한다. (폴더도 이 명령이 만든다)
- 모든 결과 파일은 메인 세션이 쓴다. analyzer와 reviewer-*는 읽기 전용이므로 반환 내용을 메인이 저장한다.

## 1단계: 분석 → `01-analysis.md`

- **요청 이해 확인을 따로 묻지 않고 바로 0단계와 1단계를 진행한다.** 요청 이해 요약은 아래 승인 질문에 함께 넣어 한 번만 확인받는다.
  (작업 전에 이해를 확인받으라는 다른 지시는 이 승인 질문으로 충족한다. 요청이 너무 모호해 분석 범위조차 정할 수 없을 때만 먼저 묻는다.)
- analyzer를 호출한다. 입력: 요청 내용.
- 아래 항목을 반환하게 한다:
  - 변경 대상 파일과 각 파일의 변경 요지
  - 참고할 기존 패턴(파일 위치)
  - 영향 범위(호출부, 다른 모듈)
  - 추가·수정할 테스트
  - 검증 명령: 저장소 루트에서 실행하는 `./gradlew` 명령, 가능한 한 모듈 단위, 끝에 `--rerun` (예: `./gradlew :order-service:check --rerun`)
  - 검증 명령의 전제 조건과 현재 충족 여부: Docker, 로컬 DB, git에서 제외된 설정 파일(예: `application-secret.properties`) 등.
    미충족이면 지금 환경에서 돌릴 수 있는 범위를 좁힌 대안 명령과, 그 대안으로는 확인되지 않는 것을 함께 적는다.
  - 새로 추가·변경하는 DB 쿼리(JPQL, 네이티브 쿼리, 파생 쿼리 메서드)가 있으면, 실제 DB로 실행하는 통합 테스트를 추가할지 선택지로 올린다 (추천과 Docker 필요 여부 포함)
  - 주의점
  - 사용자가 결정해야 할 선택지(있을 때만, 추천 포함)
- 반환 내용을 `01-analysis.md`에 저장한다.
- 한 번의 질문으로 아래를 함께 보여 주고 승인을 받는다. `waiting_user`로 바꾸고 멈춘다.
  - 요청을 어떻게 이해했는지 1~2문장
  - 계획 요약과 선택지(추천 포함)
  - 검증 전제 조건이 미충족이면: 환경을 준비할지, 대안 명령으로 좁혀 검증할지
- 사용자가 승인하면 `01-analysis.md` 끝에 `## 승인` 절(승인 내용, 고른 선택지)을 추가한다.
  **이 절이 없으면 훅이 implementer 호출을 차단한다.**

## 2단계: 구현 → `02-implementation.md`

- implementer를 호출한다. 입력: `01-analysis.md` 경로와 "계획에 없는 파일은 수정하지 않는다"는 지시.
- implementer가 선택지 때문에 멈추면 `waiting_user`로 바꾸고 사용자에게 묻는다. 답을 `## 승인`에 추가한 뒤 다시 호출한다.
- 끝나면 `git diff --name-only`와 `git status --short`를 계획의 파일 목록과 대조한다.
  계획에 없는 파일이 바뀌었으면 이유를 확인해 보고에 포함한다.
- implementer 보고와 대조 결과를 `02-implementation.md`에 저장한다. 재구현은 `## N회차` 절로 이어 쓴다.

## 3단계: 검증 (메인 세션이 직접 실행) → `03-verification.md` (훅이 기록)

- `01-analysis.md`의 검증 명령을 저장소 루트에서 **단독으로** 실행한다. `--rerun`을 붙인다.
  - 훅은 `./gradlew`로 시작하는 단독 명령만 검증으로 기록한다. `;`, `&&`, 파이프, 리다이렉트, heredoc으로 다른 명령과 묶으면 기록되지 않고 리뷰 호출이 차단된다.
  - `--rerun`이 없으면 테스트가 캐시(UP-TO-DATE)로 건너뛰어질 수 있고, 그 경우 훅이 SKIP으로 기록해 통과로 치지 않는다.
- 명령 뒤에 `| tail`, `| head` 같은 파이프를 붙이지 않는다. (파이프가 실패를 가린다)
- `git stash`, `git restore`, `git clean`, `git reset --hard`는 쓰지 않는다.
- 실패하면 오류를 정리해 2단계로 돌아간다. **검증 실패로 인한 재구현은 최대 2회**이며, 넘으면 `waiting_user`로 바꾸고 보고한다.
- Docker·DB 미기동 등 환경 문제로 보이는 실패는 코드를 고치지 말고 `waiting_user`로 바꾸고 보고한다.

## 4단계: 리뷰 → `04-review.md`

- reviewer-correctness, reviewer-maintainability, reviewer-convention을 **한 메시지에서 동시에** 호출한다.
  입력: 요청 내용, `01-analysis.md` 경로, 변경 파일 목록. (마지막 검증이 PASS가 아니면 훅이 차단한다)
  - 백그라운드 실행(`run_in_background`)을 쓰지 않는다. 세 결과가 모두 돌아올 때까지 턴을 끝내지 않는다.
    (백그라운드로 띄우고 기다리며 턴을 끝내면 작업이 중간에 멈춘 것처럼 보이고 사용자가 다시 재촉해야 한다)
- 메인 세션은 지적된 라인만 읽고 각 지적을 아래 넷 중 하나로 분류한다. 다른 분류는 만들지 않는다.
  - 반영: 실제 문제로 확인됨
  - 기각: 근거와 함께 문제 아님. 리뷰어가 이미 반론한 근거라면 그 반론에 답한다
  - 사용자 판단: 요구사항·설계 선택에 달린 것. **사용자 규칙(CLAUDE.md, rules 파일)과 기존 코드 관례가 충돌한다는 지적은 메인이 결정하지 않고 반드시 여기로 분류한다**
  - 후속 후보: 실제 문제일 수 있지만 이번 요청 범위 밖. 이번에 고치지 않고 summary에 남긴다
- 리뷰어별 원문 요약과 지적별 분류·이유를 `04-review.md`에 저장한다.
- "사용자 판단"이 있으면 `waiting_user`로 바꾸고 묻는다. 반영할 지적은 implementer에게 넘기고 3단계를 다시 실행한다.
- **리뷰 후 재구현은 최대 1회**이며, 재리뷰는 하지 않는다.

## 완료 보고 → `summary.md`

아래 내용을 `summary.md`에 저장하고 사용자에게도 보고한다. (`summary.md`가 생기면 훅이 종료를 허용한다)

- 변경 내용 요약과 변경 파일 목록
- 검증 결과(마지막 회차의 명령과 통과/실패)
- 리뷰 지적별 처리 결과(반영/기각/사용자 판단의 결정 내용/후속 후보)
- 확인한 것과 확인하지 못한 것
- PR 설명에 넣을 내용: 오래 남길 설계 결정과 그 이유(있을 때만)
- 작업 폴더 경로

커밋, 푸시, 브랜치 변경은 하지 않는다.
