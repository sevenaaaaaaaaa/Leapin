# Control plane (P1)

Local HTTP/1.1 API for scripts and the CLI (`leapin`). Implemented by
`Sources/LeapinControl/ControlServer.swift` (transport, auth, audit, SSE) and
`LeapinEngine: ControlBackend` (`Sources/LeapinRuntime/`).

## Enable / configure

Keys in the profile's `general` block (all optional; old profiles keep working):

| Key | Type | Default |
| --- | --- | --- |
| `control-enabled` | bool | `true` |
| `control-port` | int (0-65535) | `7900` |
| `control-allow-lan` | bool | `false` |

The listener starts after the proxy listeners are up. A failure to bind is
warned and never aborts engine startup. When `control-allow-lan` is false the
socket binds `127.0.0.1` only; true binds `0.0.0.0`.

## Files

Both live next to the profile store, i.e. under `$LEAPIN_PROFILE_ROOT` (default
`~/Library/Application Support/Leapin`):

- **Token** — `$LEAPIN_PROFILE_ROOT/control-token`. 32 random bytes as 64 lowercase
  hex characters, created once and reused. The directory is `0700`, the file
  is `0600`, written atomically.
- **Audit** — `$LEAPIN_PROFILE_ROOT/control-audit.jsonl`. One JSON object per line:
  `timestampMs, method, path, action, status, remote, allowed, tokenPrefix, detail`.
  Appended serially; rotated to `control-audit.jsonl.1` once it exceeds 5 MB.
  Audit write failures are swallowed and never crash the server.

Read the token with:

```bash
TOKEN=$(cat "${LEAPIN_PROFILE_ROOT:-$HOME/Library/Application Support/Leapin}/control-token")
```

## Auth

Any one of:

- `Authorization: Bearer $TOKEN`
- `X-Leapin-Token: $TOKEN`
- `?token=$TOKEN` (kept for curl convenience; prefer a header)

Comparison is constant-time. Missing or wrong credentials return `401` with
`{"ok":false,"error":"unauthorized","message":"..."}` and an audit row with
`allowed:false`.

## Routes

| Method | Path | Body / query |
| --- | --- | --- |
| GET | `/v1/status` | — |
| GET | `/v1/connections` | `?limit=` (default 50, max 1000) |
| GET | `/v1/policies` | — |
| POST | `/v1/policies/select` | `{"group":"...","outbound":"..."}` |
| POST | `/v1/reload` | — |
| POST | `/v1/explain` | `{"host":"example.com","port":443}` |
| POST | `/v1/dns/trace` | `{"host":"example.com"}` |
| POST | `/v1/http/probe` | `{"url":"https://...","timeoutMs":8000}` |
| GET | `/v1/audit` | `?limit=` |
| GET | `/v1/events` | `?since=<seq>` (SSE) |

Success bodies are JSON objects containing `"ok":true` plus the payload;
errors are `{"ok":false,"error":"<code>","message":"..."}`. Unknown paths are
`404`, known paths with a wrong method are `405`, malformed bodies are `400`.
Every response carries `Connection: close`.

### SSE

`GET /v1/events?since=N` returns `text/event-stream`, replays buffered events
(`seq > N`, last 500 retained) and then streams live flow events:

```
id: 42
event: flow
data: {"seq":42,"timestampMs":...,"phase":"opened",...}
```

A `: ping` comment is sent every 15 s. Disconnected clients are removed as
soon as the peer closes (idle receive probe), not on the next heartbeat.

## Reload semantics

`POST /v1/reload` re-reads the active profile and rule-sets. A change to
`mixed-port`, `http-port`, `socks-port` or `allow-lan` requires a listener
restart and returns `restarted:true`; everything else is hot-swapped through
forwarding boxes (`RouterBox`, `ResolverBox`, `BlockerBox`) so listening
sockets and established connections survive (`restarted:false`). The result is
`{"ok":true,"restarted":false,"applied":[...],"skipped":[...],"ruleCount":N,"elapsedMs":d}`.
MITM/capture/bypass changes are reported under `skipped` because they still
require a manual restart.

`POST /v1/policies/select` only changes the resolver selection and persists it
to the profile; it never restarts the engine, so live connections stay up.

## curl end-to-end

```bash
ROOT="${LEAPIN_PROFILE_ROOT:-$HOME/Library/Application Support/Leapin}"
TOKEN=$(cat "$ROOT/control-token"); BASE=http://127.0.0.1:7900
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/status" | jq .
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/connections?limit=5" | jq .
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"group":"Proxy","outbound":"DIRECT"}' "$BASE/v1/policies/select" | jq .
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE/v1/reload" | jq .
curl -sN -H "Authorization: Bearer $TOKEN" "$BASE/v1/events?since=0"   # Ctrl-C to stop
```

Full acceptance script: `scripts/control-e2e.sh` (isolated `LEAPIN_PROFILE_ROOT`,
asserts 401/0600/status/policies/explain/select/SSE/connections/diff-reload/
audit/404/405).
