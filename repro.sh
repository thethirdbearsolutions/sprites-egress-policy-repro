#!/bin/sh
# Sprites network policy: after a sprite makes an outbound request under an allow-all
# policy and the policy is then narrowed, responses that take longer than ~1s never
# arrive on that sprite. A sprite that is narrowed without the earlier request is fine.
#
# Needs only the `sprite` CLI, logged in. No other credentials.
# Usage: sh sprites-egress-policy-repro.sh
set -u
RED=repro-egress-red-$$
GREEN=repro-egress-green-$$
ALLOW_ALL='{"rules":[{"domain":"*","action":"allow"}]}'
ALLOW_ONE='{"rules":[{"domain":"httpbin.org","action":"allow"}]}'

policy() { sprite api "/v1/sprites/$1/policy/network" -X POST \
  -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }
code() { sprite exec -s "$1" -- curl -s -o /dev/null -m "$3" -w '%{http_code} %{time_total}s' "$2" 2>/dev/null; }
check() {  # sprite label: delay/0 (instant) and delay/5 (slow) responses from the allowed host
  fast=$(code "$1" https://httpbin.org/delay/0 15)
  slow=$(code "$1" https://httpbin.org/delay/5 15)
  case "$slow" in 200*) verdict=GREEN ;; *) verdict=RED ;; esac
  echo "$2: delay/0 -> $fast   delay/5 -> $slow   [$verdict]"
}
cleanup() { sprite destroy --force "$RED" >/dev/null 2>&1; sprite destroy --force "$GREEN" >/dev/null 2>&1; }
trap cleanup EXIT

sprite create --skip-console "$RED" >/dev/null && sprite create --skip-console "$GREEN" >/dev/null || exit 1

# Red: allow all, make one request to a host the next policy will block, then narrow.
policy "$RED" "$ALLOW_ALL"
echo "red: example.com under allow-all -> $(code "$RED" https://example.com/ 10)"
policy "$RED" "$ALLOW_ONE"

# Green: narrow straight away.
policy "$GREEN" "$ALLOW_ONE"

sleep 10  # let both policies apply
echo "red: example.com after narrowing -> $(code "$RED" https://example.com/ 5) (000 = blocked, expected)"
echo "green: example.com after narrowing -> $(code "$GREEN" https://example.com/ 5) (000 = blocked, expected)"
check "$GREEN" "green (narrowed directly)        "
check "$RED"   "red   (allow-all, request, narrow)"
