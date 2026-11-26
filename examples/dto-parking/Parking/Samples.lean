import Parking.Codecs

/-!
# Sample messages and their mutations

Every zone, length and `evCharging` choice, the responses the model gives
for them, and mutations of their JSON (a field dropped, replaced by junk, or
an extra field). `Check.lean` uses them for round trips and exactness;
`Parking.lean` exports some mutations with the Lean verdicts, so host
decoders can be checked against Lean.
-/

namespace Parking.Samples

open Lean Tribrach.Wire Payments Meters Codecs

/-- The fixed environment the exchanges use. -/
def now : Int := 1795721400
def env (approve : Bool) : Env := ⟨now, "s-1001", "tok-test-visa", authorize approve "auth-77"⟩
def envV2 (approve : Bool) (free : Nat) : EnvV2 := { env approve with chargersFree := free }

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

/-- Mutations of the samples, each with whether the shape accepts it. -/
def verdicts (c : Codec α) (samples : List α) : List (Json × Bool) :=
  samples.flatMap fun a => (variants (c.enc a)).map fun j => (j, c.ty.check j)

end Parking.Samples
