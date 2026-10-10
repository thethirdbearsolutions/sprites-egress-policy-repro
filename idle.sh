#!/bin/sh
# Finds the idle gap that kills a connection on an affected sprite. Streams a response
# from an allowed host one byte at a time (httpbin.org/drip) with gaps of 0.5s to 1.5s
# between bytes, on a red sprite and a green one, then shows what the guest sees.
# Needs only the `sprite` CLI, logged in. Destroys every sprite it creates.
# Usage: sh idle.sh
set -u
RED=idle-red-$$
GREEN=idle-green-$$
ALLOW_ALL='{"rules":[{"domain":"*","action":"allow"}]}'
ALLOW_ONE='{"rules":[{"domain":"httpbin.org","action":"allow"}]}'

policy() { sprite api "/v1/sprites/$1/policy/network" -X POST \
  -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }
x() { sprite exec -s "$1" -- sh -c "$2" 2>&1; }
drip() {  # sprite gap: 12s of one byte per gap
  n=$(awk "BEGIN { print int(12 / $2) }")
  x "$1" "curl -s -o /dev/null -m 25 -w '%{http_code} %{size_download}/$n bytes in %{time_total}s' \
    'https://httpbin.org/drip?duration=12&numbytes=$n'"
}
cleanup() { sprite destroy --force "$RED" >/dev/null 2>&1; sprite destroy --force "$GREEN" >/dev/null 2>&1; }
trap cleanup EXIT

sprite create --skip-console "$RED" >/dev/null && sprite create --skip-console "$GREEN" >/dev/null || exit 1
policy "$RED" "$ALLOW_ALL"
x "$RED" "curl -s -o /dev/null -m 10 https://example.com/" >/dev/null
policy "$RED" "$ALLOW_ONE"
policy "$GREEN" "$ALLOW_ONE"
sleep 10  # let both policies apply

echo "gap  | green | red"
for gap in 0.5 0.7 1 1.5; do
  echo "${gap}s | $(drip "$GREEN" $gap) | $(drip "$RED" $gap)"
done

for s in "$GREEN green" "$RED red"; do
  set -- $s
  echo
  echo "== $2: guest view during a stuck request (httpbin.org/delay/5)"
  x "$1" "echo nf_conntrack_tcp_timeout_established=\$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established)
    (curl -s -o /dev/null -m 12 https://httpbin.org/delay/5 &); sleep 3
    sudo -n grep 'dport=443 ' /proc/net/nf_conntrack | grep -v -e TIME_WAIT -e LAST_ACK
    ss -tni state established '( dport = :443 )' | grep -o 'bytes_retrans:[0-9]*\|lastrcv:[0-9]*' | tr '\n' ' '; echo
    echo nft: \$(command -v nft || echo none) iptables: \$(command -v iptables || echo none) bpf: \$(sudo -n ls /sys/fs/bpf | wc -l) entries
    echo default route: \$(ip route show default)"
done
