import Parking

/-!
Checks what isn't proved yet, on many generated messages (see check.sh):

1. Round trips: every value writes to JSON of the right shape and reads back
   unchanged.
2. Exactness: on each sample and on mutations of it (a field dropped, a field
   replaced by junk, an extra field), the Lean decoder accepts exactly what
   the shape accepts. The mutations and Lean's verdicts go to a file, and
   check.sh asks a JSON Schema validator for its verdicts on the same JSON.
3. Versions on the wire: a v2 server reads every v1 request as `upgrade`
   says; a v1 server reads a v2 request only when `downgradeRequest?` says
   it can; a v1 client reads every v2 response except `queued`, as
   `downgrade` says.

Run with `lake env lean --run Check.lean <out.jsonl>`.
-/

open Lean Tribrach.Wire Parking Parking.Payments Parking.Meters Parking.Codecs

def junk : List Json :=
  [Json.null, true, 0, 1, 15, 16, Json.num ⟨-15, 0⟩, Json.num ⟨25, 1⟩, Json.num ⟨20, 1⟩, "", "A1", "abc",
   "ABC123", "500", "0", "-0", "20001", "1_000", "2026-11-26T19:30:00Z",
   "2026-11-26T11:30:00-08:00", "2026-11-26T19:30:00.5Z", "2026-02-30T00:00:00Z", "started",
   "queued", "rejected", "authorized", "declined", Json.arr #[], Json.mkObj []]

def keys (j : Json) : List String :=
  match j with
  | .obj kvs => kvs.foldl (fun acc k _ => acc ++ [k]) []
  | _ => []

def without (j : Json) (k : String) : Json :=
  Json.mkObj ((keys j).filter (· != k) |>.filterMap fun k' =>
    (j.getObjVal? k').toOption.map (k', ·))

def variants (j : Json) : List Json :=
  let ks := keys j
  j :: j.setObjVal! "extra" 1 :: ks.map (without j) ++
    ks.flatMap fun k => junk.map fun v => j.setObjVal! k v

def zonesAll : List String := zones.map (·.1)
def minutesAll : List Nat := (List.range 16).map fun i => 15 * (i + 1)

def requestsV2 : List StartRequestV2 := Id.run do
  let mut out := []
  for z in zonesAll do
    for p in ["AB", "EV42XYZ9"] do
      for m in minutesAll do
        for ev in [none, some true, some false] do
          out := out ++ [⟨z, p, m, ev⟩]
  return out

def requestsV1 : List StartRequest :=
  (requestsV2.filter (·.evCharging.isNone)).map fun r => ⟨r.zone, r.plate, r.minutes⟩

def responsesV2 : List StartResponseV2 :=
  requestsV2.flatMap fun r =>
    [true, false].flatMap fun ok => [0, 2].map fun free => startV2 (envV2 ok free) r

def responsesV1 : List StartResponse :=
  requestsV1.flatMap fun r => [true, false].map fun ok => start (env ok) r

def payRequests : List AuthorizeRequest :=
  [1, 2, 499, 500, 9999, 19999, 20000].flatMap fun a =>
    currencies.map fun c => ⟨a, c, "tok-test-visa"⟩

def payResponses : List AuthorizeResponse :=
  payRequests.flatMap fun r => [true, false].map fun ok => authorize ok "auth-77" r

/-- Every `n`th element, to keep the mutation run quick. -/
def every (n : Nat) (xs : List α) : List α :=
  (xs.zipIdx.filter fun (_, i) => i % n == 0).map (·.1)

structure Report where
  lines : Array String := #[]
  failures : Nat := 0

def check (r : Report) (ok : Bool) (what : String) : Report :=
  if ok then r else { r with failures := r.failures + 1, lines := r.lines.push s!"FAIL {what}" }

/-- Mutations of the samples, with the Lean verdicts, as JSON lines. -/
def mutations (name : String) (c : Codec α) (samples : List α) (r : Report) :
    Report × Array Json := Id.run do
  let mut r := r
  let mut out := #[]
  for a in samples do
    for j in variants (c.enc a) do
      let byShape := c.ty.check j
      let byDecoder := (c.dec j).isSome
      r := check r (byShape == byDecoder) s!"{name}: decoder and shape disagree on {j.compress}"
      out := out.push (Json.mkObj [("schema", Json.str name), ("doc", j), ("lean", byShape)])
  return (r, out)

def main (args : List String) : IO UInt32 := do
  let out := args.headD "mutations.jsonl"
  let mut r : Report := {}
  -- 1. Round trips.
  r := check r (AuthorizeRequest.codec.roundtrips payRequests) "payments request round trip"
  r := check r (AuthorizeResponse.codec.roundtrips payResponses) "payments response round trip"
  r := check r (StartRequest.codec.roundtrips requestsV1) "v1 request round trip"
  r := check r (StartResponse.codec.roundtrips responsesV1) "v1 response round trip"
  r := check r (StartRequestV2.codec.roundtrips requestsV2) "v2 request round trip"
  r := check r (StartResponseV2.codec.roundtrips responsesV2) "v2 response round trip"
  -- Exchanges: status 200 exactly when the request decodes.
  for (name, cases, dec) in [
      ("payments.authorize", authorizeCases, fun j => (AuthorizeRequest.codec.dec j).isSome),
      ("meters.start v1", startV1Cases, fun j => (StartRequest.codec.dec j).isSome),
      ("meters.start v2", startV2Cases, fun j => (StartRequestV2.codec.dec j).isSome)] do
    for x in cases do
      r := check r (dec x.request == (x.status == 200)) s!"{name} {x.id}: status {x.status}"
  -- 3. Versions on the wire.
  for q in requestsV1 do
    r := check r (StartRequestV2.codec.dec (StartRequest.codec.enc q) == some (upgrade q))
      s!"v2 server misreads v1 request {repr q}"
  for q in requestsV2 do
    r := check r (StartRequest.codec.dec (StartRequestV2.codec.enc q) == downgradeRequest? q)
      s!"v1 server misreads v2 request {repr q}"
  for x in responsesV2 do
    let want := match x with | .queued _ _ => none | _ => some (downgrade x)
    r := check r (StartResponse.codec.dec (StartResponseV2.codec.enc x) == want)
      s!"v1 client misreads v2 response {repr x}"
  -- 2. Exactness on mutations.
  let mut lines : Array Json := #[]
  for (name, step) in [("payments.authorize.request", 0), ("payments.authorize.response", 1),
      ("meters.start.v1.request", 2), ("meters.start.v1.response", 3),
      ("meters.start.v2.request", 4), ("meters.start.v2.response", 5)] do
    let (r', ls) ← pure <| match step with
      | 0 => mutations name AuthorizeRequest.codec (every 3 payRequests) r
      | 1 => mutations name AuthorizeResponse.codec (every 3 payResponses) r
      | 2 => mutations name StartRequest.codec (every 7 requestsV1) r
      | 3 => mutations name StartResponse.codec (every 13 responsesV1) r
      | 4 => mutations name StartRequestV2.codec (every 13 requestsV2) r
      | _ => mutations name StartResponseV2.codec (every 37 responsesV2) r
    r := r'
    lines := lines ++ ls
  IO.FS.writeFile out ("\n".intercalate (lines.toList.map (·.compress)) ++ "\n")
  for l in r.lines.toList.take 20 do IO.println l
  if r.failures == 0 then
    IO.println s!"ok   Lean: round trips, version reads, and decoder = shape on {lines.size} mutations"
    return 0
  else
    IO.println s!"FAIL Lean: {r.failures} problems"
    return 1
