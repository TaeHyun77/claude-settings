#!/bin/bash
# feature-dev 스킬의 단계 가드.
#   guard.sh init <session_id>              스킬 시작 시 포인터 생성 (SKILL.md의 !`...`에서 호출)
#   guard.sh workdir <session_id> <rel>     작업 폴더 등록
#   guard.sh status <session_id> <status>   running | waiting_user | cancelled
#   guard.sh hook                           훅 진입점 (표준 입력: 훅 입력 JSON)
#
# 단계 완료는 모델이 적는 표시가 아니라 결과 파일로 판정한다.
# 검증 결과(03-verification.md)는 이 훅이 직접 기록하므로 모델이 PASS를 꾸밀 수 없다.

ROOT=${CLAUDE_PROJECT_DIR:-$(pwd)}
ptr() { echo "$ROOT/.work/.sessions/$1.json"; }
set_field() {  # <file> <jq 필터>
  local tmp; tmp=$(mktemp) && jq "$2" "$1" > "$tmp" && mv "$tmp" "$1"
}

case "$1" in
  init)
    [ -n "$2" ] || { echo "feature-dev: 세션 ID가 없어 가드를 켜지 못했습니다."; exit 0; }
    mkdir -p "$ROOT/.work/.sessions"
    # 같은 세션에서 다시 실행하면 새 작업으로 덮어쓴다
    echo '{"workdir":null,"status":"running"}' > "$(ptr "$2")"
    if [ -d "$ROOT/.git" ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      grep -qxF '.work/' "$ROOT/.gitignore" 2>/dev/null || { echo '.work/' >> "$ROOT/.gitignore"; echo "feature-dev: .gitignore에 .work/를 추가했습니다."; }
    fi
    echo "feature-dev: 가드 활성화 (.work/.sessions/$2.json)"
    exit 0 ;;
  workdir)
    mkdir -p "$ROOT/$3"
    set_field "$(ptr "$2")" ".workdir=\"$3\""
    echo "작업 폴더 등록: $3"; exit 0 ;;
  status)
    case "$3" in running|waiting_user|cancelled) ;; *) echo "알 수 없는 상태: $3" >&2; exit 1 ;; esac
    set_field "$(ptr "$2")" ".status=\"$3\""
    echo "상태: $3"; exit 0 ;;
  hook) ;;
  *) echo "사용법: guard.sh init|workdir|status|hook" >&2; exit 1 ;;
esac

# ---------------- 훅 ----------------
INPUT=$(cat)
j() { echo "$INPUT" | jq -r "$1 // empty"; }
EVENT=$(j .hook_event_name)
SID=$(j .session_id)
PTR=$(ptr "$SID")
[ -f "$PTR" ] || exit 0
REL=$(jq -r '.workdir // empty' "$PTR")
[ -n "$REL" ] || exit 0          # 0단계(작업 폴더 등록) 전
WD="$ROOT/$REL"
[ -d "$WD" ] || exit 0
STATUS=$(jq -r '.status // "running"' "$PTR")

block_stop() { jq -nc --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }
deny_tool() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
approved() { grep -q '^## 승인' "$WD/01-analysis.md" 2>/dev/null; }
verified() { grep -E '^- 결과: (PASS|FAIL|SKIP)$' "$WD/03-verification.md" 2>/dev/null | tail -1 | grep -q PASS; }
GUARD="bash ~/.claude/skills/feature-dev/guard.sh"

case "$EVENT" in
  Stop)
    [ -f "$WD/summary.md" ] && exit 0
    case "$STATUS" in waiting_user|cancelled) exit 0 ;; esac
    approved || exit 0                       # 승인 전에는 멈추는 것이 정상 경로
    [ "$(j .stop_hook_active)" = true ] && exit 0   # 한 번만 알리고 무한 반복은 막는다
    R=()
    [ -f "$WD/02-implementation.md" ] || R+=("구현")
    verified || R+=("검증 통과")
    [ -f "$WD/04-review.md" ] || R+=("리뷰")
    R+=("summary.md")
    block_stop "feature-dev 작업이 끝나지 않았습니다. 남은 단계: ${R[*]}. 사용자 입력이 필요해서 멈추는 것이라면 먼저 \`$GUARD status $SID waiting_user\`, 작업을 중단하려면 \`$GUARD status $SID cancelled\`를 실행하세요." ;;
  PreToolUse)
    [ "$(j .tool_name)" = Agent ] || exit 0
    case "$(j .tool_input.subagent_type)" in
      implementer) approved || deny_tool "$REL/01-analysis.md에 '## 승인' 절이 없습니다. 계획을 보여 주고 사용자 승인을 먼저 받으세요." ;;
      reviewer-*) verified || deny_tool "$REL/03-verification.md의 마지막 검증 결과가 PASS가 아닙니다. 검증을 통과한 뒤 리뷰를 호출하세요." ;;
    esac ;;
  PostToolUse|PostToolUseFailure)
    [ "$(j .tool_name)" = Bash ] || exit 0
    [ -n "$(j .agent_id)" ] && exit 0        # 서브에이전트의 빌드는 메인 검증으로 치지 않는다
    approved || exit 0
    CMD=$(j .tool_input.command)
    # 글자로만 들어간 gradlew(heredoc, echo)나 다른 명령과 묶인 실행은 검증으로 치지 않는다
    #  — 묶인 명령은 어느 부분이 성공했는지 알 수 없어서 거짓 PASS가 생긴다
    case "$CMD" in *$'\n'*|*';'*|*'&&'*|*'||'*|*'|'*|*'>'*|*'<'*) exit 0 ;; esac
    echo "$CMD" | grep -qE '^\./gradlew[[:space:]]' || exit 0
    F="$WD/03-verification.md"
    N=$(( $(cat "$F" 2>/dev/null | grep -cE '^## [0-9]+회차$') + 1 ))
    if [ "$EVENT" = PostToolUse ]; then
      # test 태스크가 UP-TO-DATE/FROM-CACHE면 테스트가 실제로 돌지 않은 것이라 통과로 치지 않는다
      if j .tool_response.stdout | grep -qE ':test (UP-TO-DATE|FROM-CACHE)'; then
        printf '## %d회차\n- 명령: `%s`\n- 결과: SKIP\n- 사유: test 태스크가 실행되지 않음(UP-TO-DATE/FROM-CACHE). `--rerun`을 붙여 다시 실행하세요.\n\n' "$N" "$CMD" >> "$F"
      else
        printf '## %d회차\n- 명령: `%s`\n- 결과: PASS\n\n' "$N" "$CMD" >> "$F"
      fi
    else
      printf '## %d회차\n- 명령: `%s`\n- 결과: FAIL\n```\n%s\n```\n\n' "$N" "$CMD" "$(j .error | head -20)" >> "$F"
    fi ;;
  UserPromptSubmit)
    [ "$STATUS" = waiting_user ] && set_field "$PTR" '.status="running"' ;;
esac
exit 0
