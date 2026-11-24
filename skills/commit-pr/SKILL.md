---
name: commit-pr
description: 현재 작업 트리의 변경 사항으로 브랜치명·커밋 메시지·PR 내용을 추천하고, 사용자가 확인하면 브랜치 생성, 커밋, 푸시, PR 생성까지 진행한다
disable-model-invocation: true
allowed-tools: Bash(cat ~/.claude/rules/git-workflow.md), Bash(git *), Bash(gh pr create *), Bash(gh pr view *), Bash(./gradlew *)
---

# 변경 사항 커밋·PR 생성

`/commit-pr` 호출 자체가 커밋·푸시·PR 생성 지시다. 단, 아래 확인 질문에 사용자가 답하기 전에는 아무것도 실행하지 않는다.

## 규칙 (커밋·브랜치·PR 형식은 이 내용만 따른다)

!`cat ~/.claude/rules/git-workflow.md`

## 현재 상태

- 현재 브랜치: !`git branch --show-current`
- 변경 파일:
!`git status --short`
- 변경 통계 (HEAD 대비):
!`git diff HEAD --stat`

## 절차

### 1. 분석

- 대상은 HEAD 이후 아직 커밋하지 않은 변경 전체(staged, unstaged, untracked)다. `git diff HEAD`와 새 파일 내용을 읽고 판단한다.
- 변경이 없으면 그렇게 알리고 끝낸다.
- 커밋하면 안 되는 파일(`.env`, 인증 정보, `*secret*`, `build/`, `.work/`, `dump.rdb` 같은 실행 산출물)은 제외 목록으로 분리한다.
- 서로 다른 목적의 변경이 섞여 있으면 커밋 분할안(커밋별 파일 목록과 메시지)을 만든다. 자동으로 나누지 않고 질문에 올린다.

### 2. 확인 질문 (AskUserQuestion 한 번)

질문 문장은 "브랜치 `<브랜치명>`, 커밋 `<메시지>`, PR `<제목>`으로 진행할까요?" 형식으로 쓴다. 질문 창만 보고도 판단할 수 있도록 아래를 질문 또는 선택지 설명에 담는다.

- 선택지: 추천안(Recommended), 대안 1~2개(타입이나 표현이 다른 것). 사용자가 직접 입력하는 경우는 Other로 받는다.
- 각 선택지에 브랜치명, 커밋 메시지(본문 포함), PR 제목을 모두 적는다. PR 본문은 추천안의 preview에 넣는다.
- 포함할 파일 수와 제외할 파일이 있으면 그 목록.
- 현재 브랜치가 main이 아니면 질문을 하나 더 넣는다: "현재 브랜치에 커밋" / "최신 main에서 새 브랜치". 현재 브랜치에 main에 없는 커밋이 있으면 PR에 함께 들어간다는 점을 적는다.
- 커밋 분할안이 있으면 "분할해서 커밋" / "한 커밋으로"를 묻는다. PR은 하나로 만든다.

사용자가 Other로 직접 입력하면, 규칙(형식, 50자, 영문 소문자 브랜치)에 어긋나는지만 확인한다. 어긋나면 고친 안을 한 번 더 확인받고, 맞으면 그대로 진행한다.

### 3. 커밋 전 검증

- 변경 파일이 속한 Gradle 모듈만 `./gradlew :<모듈>:test --rerun`으로 실행한다. 모듈이 여러 개면 한 명령에 태스크를 나열한다.
- 명령은 단독으로 실행한다. 파이프(`| tail` 등), `&&`, 리다이렉트로 묶지 않는다. 파이프는 실패를 가린다.
- 문서·설정 파일만 바뀌었으면 건너뛰고, 건너뛴 사실을 보고에 적는다.
- `common` 모듈이 바뀌었으면 의존 모듈은 테스트하지 않았다는 점을 보고에 적는다.
- 실패하면 멈추고 실패 내용을 보고한다. Docker나 DB 미기동처럼 환경 문제로 보이면 그렇게 구분해서 알리고, 검증 없이 진행할지 사용자에게 묻는다.

### 4. 실행

- 새 브랜치: `git checkout main` → `git pull --ff-only` → `git checkout -b <브랜치명>`. 작업 트리 변경과 충돌해 checkout이나 pull이 실패하면 멈추고 보고한다.
- 현재 브랜치 사용: 브랜치를 바꾸지 않는다.
- `git add <파일 지정>`으로 올리고, `git diff --staged --stat`으로 포함 내용을 확인한 뒤 커밋한다. 분할이면 커밋마다 반복한다.
- `git push -u origin <브랜치명>`
- `gh pr view`로 이미 열린 PR이 있는지 확인한다. 있으면 새로 만들지 않고 그 URL을 보고한다. 없으면 `gh pr create --base main --title "<제목>" --body "<본문>"`.

### 금지

- `git add .`, `git add -A`, `git stash`, `git reset --hard`, `git restore`, `git clean`, `--force` 푸시, main에 직접 커밋·푸시.
- 실패를 되돌리려고 위 명령을 쓰지 않는다. 멈추고 현재 상태(브랜치, 커밋 여부, 푸시 여부)를 보고한다.

## 보고

- 브랜치명, 커밋 해시와 메시지, PR URL
- 검증 명령과 결과(통과/실패/건너뜀과 이유)
- 제외한 파일
