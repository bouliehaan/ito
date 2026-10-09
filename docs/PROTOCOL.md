# protocol v1

Phone listens on TCP **6969**, advertises `_ito._tcp` (TXT `fp=<8 hex>`, `v=1`). The Mac connects.

## framing

Every message on the socket: `u16 big-endian length` + bytes (≤ 65535).

## handshake

`Noise_XX_25519_ChaChaPoly_SHA256`, prologue `ito/1`, Mac = initiator.

| msg | dir | payload |
|---|---|---|
| 1 | mac → phone | empty |
| 2 | phone → mac | JSON `{"name": "...", "v": 1}` |
| 3 | mac → phone | JSON `{"name": "...", "v": 1}` |

After msg 3, every frame is a Noise transport message whose plaintext is
`kind (1 byte)` + body:

- `1` JSON object, UTF-8, field `t` = type
- `2` audio: `u32 BE sequence` + 640 bytes PCM s16le, 16 kHz mono (20 ms)

## auth

The phone's first JSON: `{"t":"auth","state": "trusted" | "pairing" | "refused", "why"?}`.
Refused is followed by close.

## pairing (state = pairing)

```
phone → {"t":"pair.commit","c": hex SHA256("ito/commit" || Np)}
mac   → {"t":"pair.nonce","n": hex Nm}          (32 bytes)
phone → {"t":"pair.reveal","n": hex Np}         (mac checks c)
both show SAS = SHA256("ito/sas" || h || Nm || Np)[0..8] as u64 BE mod 10^6, 6 digits
each  → {"t":"pair.ok"}  or  {"t":"pair.no","why"?}
phone → {"t":"auth","state":"trusted"}   once both sides said ok; both pin the other's key
```

`h` is the Noise handshake hash of this connection.

## mac → phone

| t | fields | |
|---|---|---|
| `sync` | `sms`, `mms`, `calls` (highest ids held), `contacts` (hash held) | |
| `send` | `cid`, `to: [number]`, `body` | 1:1 text; ends that person's group context |
| `gsend` | `cid`, `g`, `body` | fan out to a group |
| `group.save` | `cid`, `g: {id?, name, members, relay}` | → `group.saved {cid, id}` |
| `group.delete` | `id` | |
| `refile` | `id` (sms row), `g` (group id or null) | move a received text in/out of a group; into a relay group relays it |
| `photo` | `k` (contact lookup key) | → `photo {k, jpeg: base64 \| null}` |
| `mmspart` | `pid` | → `mmspart {pid, ct, i, n, data}` chunks, or `{pid, missing: true}` |
| `dial` | `n` | |
| `answer` / `decline` / `hangup` | `id` | |
| `dtmf` | `id`, `d` | |
| `hold` | `id`, `on` | |
| `audio` | `id`, `on` | take (or release) a call's audio on this Mac |
| `ping` | | → `pong`. Every 15 s; the phone drops a Mac silent for 45 s |

## phone → mac

| t | fields |
|---|---|
| `hello` | `name`, `model`, `android`, `number`, `fp`, `system` (privileged install), `callAudio` (`ok` / `unsupported` / `needs-system-install`), `sms` (permissions ok) |
| `status` | `batt`, `charging`, `plugged`, `temp`, `wifi`, `ims` (`wifi` / `cellular` / `registering` / `off` / `unknown`) — on connect, every 60 s, on IMS change |
| `sms` | `rows`, `done`? — upsert |
| `sms.ids` | `ids`, `done` — the phone's full id list, chunked; the Mac deletes what is missing |
| `mms` / `mms.ids` | same |
| `contacts` | `rows`, `done`, `hash` (on the last chunk) — full replace |
| `calls` | `rows` — call log, upsert |
| `groups` | `groups` — full replace |
| `call` | `id`, `state` (`ringing` / `dialing` / `active` / `held` / `ended`), `n`, `nm`, `dir`, `since`, `audio`, `full` |
| `sent` | `cid`, `to`, `ok`, `err` |
| `synced` | end of a sync |
| `error` | `for`, `msg` |

Rows are packed under 48 KB of JSON per frame.

### rows

- **sms** `{id, th, a, b, d, ds, ty, st, r, ito?, g?, gm?, rl?}`: Android's `_id, thread_id,
  address, body, date, date_sent, type, status, read`; `ito` = sent by ito; `g` group,
  `gm` group-message id (shared by every copy of one group message), `rl` = relay copy
  (plumbing, never shown).
- **mms** `{id, th, d, box, r, from, to[], b, parts[{pid, ct, name}], undl?}`: `undl` = a
  notification for an MMS that never downloaded.
- **contact** `{k, n, p[], ph}`
- **call log** `{id, n, nm, ty, d, dur}`: `ty` as `CallLog.Calls.TYPE`.
- **group** `{id, name, members[], relay, created}`
