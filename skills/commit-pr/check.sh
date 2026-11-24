#!/bin/bash
# commit-pr 스킬의 PreToolUse 훅. git commit 직전에 커밋 대상(staged) .java 파일만 린트(Checkstyle)로 검사하고,
# 위반이 있으면 deny로 커밋을 막는다. 다른 Bash 명령은 그대로 통과시킨다.
# 검사 자체는 공용 실행기(~/.claude/tools/checkstyle/lint-java.sh)가 하고, 여기서는 시점과 대상만 정한다.
#
# 작업 트리가 아니라 staged 내용을 검사한다 — 커밋에 넣지 않은 수정이 섞이면 실제 커밋과 다른 결과가 나오기 때문.

LINT="$HOME/.claude/tools/checkstyle/lint-java.sh"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# && 등으로 묶인 명령도 잡도록 명령 안 어디에 있든 찾는다
echo "$CMD" | grep -qE '(^|[;&|(][[:space:]]*|[[:space:]])git[[:space:]]+commit([[:space:]]|$)' || exit 0

# -a/--all은 staged 목록에 없는 파일까지 커밋해 검사를 빠져나간다
if echo "$CMD" | grep -qE 'git[[:space:]]+commit.*([[:space:]]-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|[[:space:]]--all([[:space:]]|$))'; then
  deny "commit-pr에서는 git commit -a/--all을 쓰지 않습니다. 파일을 지정해 git add한 뒤 커밋하세요."
fi

TOP=$(git -C "${CWD:-${CLAUDE_PROJECT_DIR:-.}}" rev-parse --show-toplevel 2>/dev/null) || exit 0

FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done \
  < <(git -C "$TOP" diff --staged --name-only --diff-filter=ACMR -z -- '*.java')
[ ${#FILES[@]} -eq 0 ] && exit 0

[ -f "$LINT" ] || deny "린트 검사를 실행할 수 없습니다: $LINT 이 없습니다. 커밋하지 말고 사용자에게 알리세요."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$TOP" checkout-index --prefix="$TMP/" -- "${FILES[@]}" \
  || deny "린트 검사를 실행할 수 없습니다: staged 파일을 꺼내지 못했습니다. 커밋하지 말고 사용자에게 알리세요."

OUT=$(cd "$TMP" && bash "$LINT" "${FILES[@]}")
case $? in
  0) exit 0 ;;
  1)
    COUNT=$(echo "$OUT" | grep -c .)
    deny "린트(Checkstyle) 위반 ${COUNT}건 (커밋 대상 ${#FILES[@]}개 파일만 검사). 바로 고치지 말고, 사용자에게 위반 목록과 수정안을 보여 준 뒤 수정할지 물으세요.
$(echo "$OUT" | head -30)$([ "$COUNT" -gt 30 ] && echo "
... 외 $((COUNT - 30))건")" ;;
  *)
    deny "린트 검사를 실행할 수 없습니다. 커밋하지 말고 사용자에게 알리세요.
$OUT" ;;
esac
