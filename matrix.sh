#!/bin/sh
# Runs each policy sequence on its own fresh sprite, in parallel, then checks whether
# a slow response (httpbin.org/delay/5) from an allowed host arrives.
# Needs only the `sprite` CLI, logged in. Destroys every sprite it creates.
# Usage: sh matrix.sh
set -u
P=matrix-$$
ALLOW_ALL='{"rules":[{"domain":"*","action":"allow"}]}'
ALLOW_ONE='{"rules":[{"domain":"httpbin.org","action":"allow"}]}'
CLEAR='{"rules":[]}'
OUT=$(mktemp -d)

policy() { sprite api "/v1/sprites/$1/policy/network" -X POST \
  -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }
fetch() { sprite exec -s "$1" -- curl -s -o /dev/null -m 10 "$2" >/dev/null 2>&1; }
slow() { sprite exec -s "$1" -- curl -s -o /dev/null -m 15 -w '%{http_code}' https://httpbin.org/delay/5 2>/dev/null; }
verdict() { [ "$1" = 200 ] && echo "arrives  (GREEN)" || echo "times out (RED)"; }

run_case() {  # n label steps...
  n=$1; label=$2; shift 2; s=$P-$n
  sprite create --skip-console "$s" >/dev/null 2>&1 || { echo "$n|$label|create failed" > "$OUT/$n"; return; }
  for step in "$@"; do
    case "$step" in
      allow-all) policy "$s" "$ALLOW_ALL" ;;
      narrow)    policy "$s" "$ALLOW_ONE" ;;
      clear)     policy "$s" "$CLEAR" ;;
      fetch:*)   fetch "$s" "${step#fetch:}" ;;
      wait)      sleep 10 ;;
    esac
  done
  sleep 10
  printf '%s|%s|%s\n' "$n" "$label" "$(verdict "$(slow "$s")")" > "$OUT/$n"
  sprite destroy --force "$s" >/dev/null 2>&1
}

run_case 1 "no policy" &
run_case 2 "allow-all" allow-all &
run_case 3 "narrow" narrow &
run_case 4 "narrow, clear, narrow" narrow wait clear wait narrow &
run_case 5 "allow-all, narrow (no request between)" allow-all narrow &
run_case 6 "allow-all, wait, narrow (no request between)" allow-all wait wait wait wait wait narrow &
run_case 7 "allow-all, request example.com (no narrow)" allow-all fetch:https://example.com/ &
run_case 8 "allow-all, request example.com, narrow" allow-all fetch:https://example.com/ narrow &
run_case 9 "allow-all, request www.iana.org, narrow" allow-all fetch:https://www.iana.org/ narrow &
run_case 10 "allow-all, request example.com, narrow, then clear" allow-all fetch:https://example.com/ narrow wait clear &
wait

echo "case | sequence | delay/5 from an allowed host"
cat "$OUT"/* | sort -n -t'|' -k1 | sed 's/|/ | /g'
rm -rf "$OUT"
