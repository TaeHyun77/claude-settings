#!/bin/sh
input=$(cat)

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

if [ -n "$used" ] && [ -n "$remaining" ]; then
  used_int=$(printf "%.0f" "$used")
  remaining_int=$(printf "%.0f" "$remaining")
  token_info=" | ctx: ${used_int}% used / ${remaining_int}% left"
else
  token_info=""
fi

printf "%s:%s %s%s" "$(hostname -s)" "$(basename "$(pwd)")" "$(whoami)" "$token_info"
