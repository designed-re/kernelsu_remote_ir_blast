# Termux IR Hub — API Reference

HTTP webhook API. Android device running Termux + Termux:API fires IR signals via
`termux-infrared-transmit` using pre-extracted raw pulse/space timing arrays
(NEC 38kHz). Machine-readable spec: see [`openapi.yaml`](openapi.yaml).

- Base URL: `http://<device-ip>:<port>` (default port `5000`, set in `config.json`)
- Content-Type: `application/json` (for POST bodies)
- All responses are JSON.

## Authentication

Optional. Enabled only when `config.json` `auth_token` is non-empty. When enabled,
every request except `GET /health` must carry the token via one of:

- Header `Authorization: Bearer <token>`
- Header `X-Token: <token>`
- Query `?token=<token>`

Missing/invalid token → `401 {"ok":false,"error":"unauthorized"}`.

## Endpoints

### GET /health
Liveness. **No auth.** Returns service status and configured command count.
```
200 {"ok":true,"service":"termux-ir-hub","codes":8}
```

### GET /ac
List available commands from `ir_codes.json` (keys starting with `_` excluded).
```
200 {"ok":true,"commands":["fan","mode","power","sleep","swing","temp_down","temp_up","turbo"]}
```

### GET|POST /ac/{command}
Fire a named command. Looks up `command` in `ir_codes.json` and runs
`termux-infrared-transmit -f <carrier> <pattern>`.

Path param `command`: one of the names from `GET /ac`.

Response (200, IR emitted):
```json
{"ok":true,"command":"power","carrier":38000,"rc":0,"elapsed_ms":516,"output":""}
```
- `rc`: underlying exit code. `0`=success, `126`=stub/failure-marker,
  `127`=command missing, `124`=timeout.
- `output`: `termux-infrared-transmit` stdout/stderr; empty on success.
- `ok` is `true` **only if IR was actually emitted**. A Play-Store stub Termux:API
  prints a warning and exits 0 — the hub detects this and returns `ok:false` + `502`.

Errors: `404 {"ok":false,"error":"unknown command: <name>"}` | `502` (transmit
failed, see `output`).

### POST /ir
Fire ad-hoc raw timings not stored in `ir_codes.json`. Body:

| field | type | required | notes |
|---|---|---|---|
| `carrier` | int | no | Hz, default `config.default_carrier` (38000) |
| `pattern` | string | one of | comma-separated pulse/space µs |
| `timings` | int[] | one of | array of pulse/space µs |

Pattern = pulse(ON)/space(OFF) microseconds, starts with a pulse. May include a
trailing repeat frame (odd count allowed).

Examples:
```json
{"carrier":38000,"pattern":"9000,4500,560,1690,560,560,560,1690"}
{"carrier":38000,"timings":[9000,4500,560,1690,560,560]}
```
Response (200): `{"ok":true,"carrier":38000,"rc":0,"output":""}`
Errors: `400` (`pattern/timings required` | `bad carrier` | `bad timings`) | `502`.

### POST /reload
Re-read `ir_codes.json` from disk so edits take effect without restarting.
```json
200 {"ok":true,"codes":8}
```

## Pre-configured commands (ir_codes.json)

| Endpoint | Korean | timings |
|---|---|---|
| `/ac/power` | 전원 | 71 |
| `/ac/sleep` | 수면풍 | 71 |
| `/ac/turbo` | 터보풍 | 71 |
| `/ac/mode` | 모드변경 | 71 |
| `/ac/temp_up` | 설정온도업 | 71 |
| `/ac/temp_down` | 설정온도다운 | 71 |
| `/ac/fan` | 풍량조절 | 71 |
| `/ac/swing` | 날개회전 | 71 |

All NEC 38kHz; each array includes a single repeat frame at the end.

## Examples

```sh
# list
curl http://192.168.31.140:5000/ac

# fire power (no auth)
curl http://192.168.31.140:5000/ac/power

# fire temp_up (with auth token)
curl -H 'X-Token: mytoken' http://192.168.31.140:5000/ac/temp_up

# ad-hoc raw
curl -X POST http://192.168.31.140:5000/ir \
  -H 'Content-Type: application/json' \
  -d '{"carrier":38000,"pattern":"9000,4500,560,1690"}'

# reload after editing ir_codes.json
curl -X POST -H 'X-Token: mytoken' http://192.168.31.140:5000/reload
```

Home Assistant RESTful switch example:
```yaml
rest_command:
  ac_power:
    url: "http://192.168.31.140:5000/ac/power"
    method: GET
    headers:
      X-Token: "mytoken"
```

Node-RED: HTTP in node → GET `/ac/{{payload.command}}` → HTTP request to the hub.

## Status codes

| HTTP | meaning |
|---|---|
| 200 | IR emitted (`ok:true`) |
| 400 | bad request body (`/ir`) |
| 401 | auth required / invalid token |
| 404 | unknown command (`/ac/{command}`) |
| 502 | transmit failed — inspect `output` (stub app / permission / missing IR hardware) |

## Notes for AI agents / automation

- Treat `ok:false` with `rc:126` and `output` containing "Google Play" as a
  **device setup error**, not a transient failure — do not blindly retry; the
  device needs the F-Droid build of Termux:API.
- `/ac/temp_up` and `/ac/temp_down` are step buttons, not absolute setpoints;
  call repeatedly to change the temperature by N steps.
- Transmissions are serialized (single IR emitter). Concurrent requests are
  queued; do not fan-out high parallelism expecting order.
- Edit `ir_codes.json` then `POST /reload` — no restart needed.
