# Parking: contracts as the source of DTOs

Two services and a client, talking JSON over HTTP:

| Part | Owns | Calls |
| --- | --- | --- |
| payments | `payments.authorize` | nothing |
| meters | `meters.start` v1 and v2 | `payments.authorize` |
| a client (Go and Swift, later PRs) | nothing | `meters.start` v1 |

Each message is described once in `Parking/Codecs.lean`. That one
description gives the JSON Schema in `exported/schemas/` and the Lean
decoder. It will also give the generated Go and Swift DTOs. `lake build`
writes `exported/` and fails if any proof breaks.

## Proved (Lean, every build)

| Theorem | Says |
| --- | --- |
| `Payments.authorize_exact`, `authorize_bounded` | An authorization is for exactly the amount asked, and never over the limit |
| `Meters.started_is_paid` | Every started session was authorized for exactly what it charged |
| `Meters.expiry_exact` | A session starts now and runs exactly the minutes asked |
| `Meters.charge_within_limit` | The dearest valid session (zone A1, 240 minutes, 2,000 cents) fits under payments' limit. This is where meters relies on payments |
| `Meters.start_succeeds` | Composed with the real payments service, a valid request starts a session whenever the card approves |
| `Meters.requestVersion` | The v1 to v2 request change is a `Tribrach.Version`: every v1 request comes back unchanged after an upgrade, and whatever a v1 server can read upgrades back to itself |
| `Meters.v2_serves_v1` | A v2 server on the v1 route answers every v1 request exactly as a v1 server would (a `Tribrach.Serves`) |
| `Meters.v1_never_queued` | v1 requests never get v2's new `queued` answer |
| `Meters.rollback_safe` | A v1 server reads a v2 request only when nothing is lost, and then answers as v2 would. It follows from the two above by `Serves.rollback` |

`Meters.v2Revision` is the contract history record for v2, written by
`Revision.ofVersion` from `requestVersion`: kind `extend both`, evidence
`checked`.

## Tested (check.sh), not yet proved

The theorems talk about Lean values. That the JSON layer matches them is
checked on many messages, not yet proved:

- Round trips: every sample value writes to JSON of the right shape and
  reads back unchanged. The samples cover every zone, every valid length and
  every `evCharging` choice.
- Exactness: about 10,000 mutated messages (a field dropped, replaced by
  junk, or an extra field added). On each one the Lean decoder, the Lean
  shape check and a JSON Schema validator all agree. The validator has two
  small extensions: ECMA-262 `$`, and the `x-tribrach` bounds on decimal
  strings.
- Versions on the wire: a v2 server reads each v1 request as `upgrade`
  says. A v1 server reads a v2 request exactly when `downgradeRequest?`
  allows. A v1 client reads every v2 response except `queued`.
- Exchanges: every recorded request, call and response fits its schema, and
  status 200 means exactly that the request decodes.

## Planted breaks

| Break | Result | Where |
| --- | --- | --- |
| Payments lowers its limit to 1,000 | `Meters.charge_within_limit` no longer proves, so the build fails in meters, not payments | check.sh runs it |
| A request asks for 0 or 50 minutes, an unknown zone, or a lowercase plate | The decoder rejects it (status 400) before any model code runs | `exported/exchanges/meters.start.v1.json` |
| A v2 field (`evCharging`) reaches a v1 server | It is rejected, never silently dropped | case `v2-field-on-v1` |
| v2 adds `queued` with no v1 form | `downgrade` must map it, or `v2_serves_v1` doesn't typecheck | by construction |

## Verdicts

`exported/verdicts/*.json` (`tribrach.verdicts.v1`) hold about 2,400
mutated messages, each marked with whether the schema accepts it. A host
decoder must accept exactly the ones marked `accept`, which is how the Go
and Swift generators are checked against Lean.

## Exchanges

`exported/exchanges/*.json` (`tribrach.exchanges.v1`, see
`schema/exchanges.schema.json`) come from running the model. Each case gives
the following, for host handlers to replay:

- the fixed clock, ids and stubbed card answer;
- the request;
- the calls to other services, with their answers;
- the status and the response.

## Wire choices

- Money is in minor units, as a decimal string (`"2000"`). Bounds are under
  `x-tribrach`, since JSON Schema can't bound a string's value.
- Times are RFC 3339 instants (`2026-11-26T19:30:00Z`). Lean reads any
  offset and writes UTC.
- Optional fields are left out when absent; `null` is not absent.
- Objects are closed: an unknown field is an error, which is what makes
  rollback safe.
