# Sprites: slow responses never arrive after narrowing an allow-all network policy

A sprite makes an outbound request while its network policy allows all domains. Then the policy is narrowed to a single allowed domain. After that, responses from the allowed domain that take longer than about a second never arrive. Responses that come back immediately still do.

A sprite narrowed without that earlier request is fine. Once a sprite is in this state, clearing the policy doesn't recover it.

The scripts need only the `sprite` CLI, logged in. No other credentials are needed. Each script destroys every sprite it creates.

## `repro.sh`: one red, one green

Takes about 35 seconds.

1. Create two sprites.
2. On the red one: set `{"rules":[{"domain":"*","action":"allow"}]}`, run `curl https://example.com/`, then set `{"rules":[{"domain":"httpbin.org","action":"allow"}]}`.
3. On the green one: set the `httpbin.org` policy directly.
4. After 10 seconds, fetch `https://httpbin.org/delay/0` and `https://httpbin.org/delay/5` on both.

**Expected:** both sprites get 200 for both URLs.

**Actual** (2026-10-10 16:17 UTC):

```
red: example.com under allow-all -> 200 0.078920s
red: example.com after narrowing -> 000 0.001201s (000 = blocked, expected)
green: example.com after narrowing -> 000 0.001289s (000 = blocked, expected)
green (narrowed directly)        : delay/0 -> 200 0.285529s   delay/5 -> 200 5.130732s   [GREEN]
red   (allow-all, request, narrow): delay/0 -> 200 0.322763s   delay/5 -> 000 15.002134s   [RED]
```

## `matrix.sh`: which steps matter

Takes about a minute. Each sequence runs on its own fresh sprite, and the check afterwards is `https://httpbin.org/delay/5` with a 15s timeout.

Output (2026-10-10 19:21 UTC):

```
case | sequence | delay/5 from an allowed host
1 | no policy | arrives  (GREEN)
2 | allow-all | arrives  (GREEN)
3 | narrow | arrives  (GREEN)
4 | narrow, clear, narrow | arrives  (GREEN)
5 | allow-all, narrow (no request between) | arrives  (GREEN)
6 | allow-all, wait, narrow (no request between) | arrives  (GREEN)
7 | allow-all, request example.com (no narrow) | arrives  (GREEN)
8 | allow-all, request example.com, narrow | times out (RED)
9 | allow-all, request www.iana.org, narrow | times out (RED)
10 | allow-all, request example.com, narrow, then clear | times out (RED)
```

It takes both a request under allow-all and narrowing afterwards (cases 5–9). Which host was requested doesn't matter (8, 9). Clearing the policy afterwards doesn't recover the sprite (10).

## `idle.sh`: it's the idle gap

Takes about two minutes. Streams a response from the allowed host one byte at a time, with a fixed gap between bytes, on a red sprite and a green one. Then it looks at the guest's own view of a stuck request.

Output (2026-10-10 20:35 UTC):

```
gap  | green | red
0.5s | 200 24/24 bytes in 12.455430s | 200 24/24 bytes in 12.020366s
0.7s | 200 17/17 bytes in 11.482692s | 200 17/17 bytes in 11.512087s
1s | 200 12/12 bytes in 11.170111s | 200 1/12 bytes in 25.001796s
1.5s | 200 8/8 bytes in 10.826474s | 200 1/8 bytes in 25.002224s
```

On a red sprite a connection survives as long as bytes keep arriving at least every 0.7s, for as long as that lasts. A gap of 1s or more kills it after the first byte. So it's the time a connection sits idle that matters, not its age or how many bytes it carries.

The guest doesn't hold the stuck state. During a stuck request, red and green look the same from inside:

- `nf_conntrack_tcp_timeout_established` is 432000 on both, and the stuck connection is listed `ESTABLISHED` with that full timeout.
- There's no `nft`, no `iptables` and nothing in `/sys/fs/bpf`.
- All traffic leaves through the default route via `10.0.0.2` on `spr0`.

On a red sprite, a connection to an address that DNS never returned for an allowed domain (`curl --resolve httpbin.org:443:1.1.1.1`) is refused instantly, the same as on a green one. The allowlist itself still works.

## Where the cutoff falls

On an affected sprite, with responses from the allowed host:

| Request | Result |
|---|---|
| `httpbin.org/delay/0` | 200 in 0.2s |
| `httpbin.org/delay/1` | 200 in 1.1s |
| `httpbin.org/delay/2` | times out at 15s |
| `httpbin.org/delay/5` | times out at 15s |
| `httpbin.org/bytes/200000` (102,400 bytes, sent at once) | arrives in 0.5s |
| `httpbin.org/drip?duration=30&numbytes=30` | times out; arrives complete in 30.7s on an unaffected sprite |

## How it showed up for us

Claude Code (CLI 2.1.251) was running in sprites locked to `api.anthropic.com`, after a check under allow-all.

- Streamed responses got their first 860–900 bytes and then nothing. The connection reset about 70s after each attempt started.
- Non-streaming requests got no response and timed out at 5 minutes.
- On the same sprite, unauthenticated requests to the same host (instant 401s) returned in about 0.1s, with request bodies up to 60KB.
- Stuck connections ended in `FIN-WAIT-1` with unacknowledged retransmits (`ss -tni`).
- Clamping the route MSS (`ip route replace … mtu 1420 advmss 1360`) made no difference.

## Environment

- Sprite version `0.0.2-beta.5`.
- Link MTU 1500 on `spr0`.
- Policies set with `POST /v1/sprites/{name}/policy/network` (`sprite api`).
