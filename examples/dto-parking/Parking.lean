import Parking.Codecs

/-!
# Example: parking contracts as the source of DTOs

Two services and a client, all talking JSON over HTTP:

* `payments.authorize` (`Parking.Payments`): authorizes a charge.
* `meters.start` v1 and v2 (`Parking.Meters`): starts a parking session,
  charging through payments first.

`Parking.Codecs` describes each message once. Compiling this module writes
`exported/`:

* `schemas/*.json`: one JSON Schema per message, for other tools and for
  generating Go and Swift DTOs;
* `exchanges/*.json`: requests, the calls they cause and the responses, made
  by running the Lean model, for hosts to replay against their handlers.

The proofs are in `Parking.Meters` and `Parking.Payments`; `Check.lean` and
`check.sh` test what isn't proved yet (see the README).
-/

namespace Parking

open Lean Tribrach Tribrach.Schema Tribrach.Wire Payments Meters Codecs

def schemaBase : String := "https://example.com/parking/schemas/"

def schemaOf (name title : String) (c : Codec α) : Schema :=
  { id := schemaBase ++ name ++ ".json", title, root := c.ty,
    description := some "Generated from examples/dto-parking/Parking/Codecs.lean." }

def schemas : List (String × Schema) := [
  ("payments.authorize.request", schemaOf "payments.authorize.request"
    "payments.authorize request" AuthorizeRequest.codec),
  ("payments.authorize.response", schemaOf "payments.authorize.response"
    "payments.authorize response" AuthorizeResponse.codec),
  ("meters.start.v1.request", schemaOf "meters.start.v1.request"
    "meters.start v1 request" StartRequest.codec),
  ("meters.start.v1.response", schemaOf "meters.start.v1.response"
    "meters.start v1 response" StartResponse.codec),
  ("meters.start.v2.request", schemaOf "meters.start.v2.request"
    "meters.start v2 request" StartRequestV2.codec),
  ("meters.start.v2.response", schemaOf "meters.start.v2.response"
    "meters.start v2 response" StartResponseV2.codec)]

/-! ## Exchanges, made by running the model -/

/-- The fixed clock and ids every case uses: 2026-11-26T19:30:00Z. -/
def now : Int := 1795721400
def given (approve : Bool) (extra : List (String × Json) := []) : Json :=
  Json.mkObj ([("now", Json.str (formatInstant now)), ("sessionId", "s-1001"),
    ("token", "tok-test-visa"), ("card", Json.str (if approve then "approve" else "decline")),
    ("authId", "auth-77")] ++ extra)

def env (approve : Bool) : Env := ⟨now, "s-1001", "tok-test-visa", authorize approve "auth-77"⟩

/-- The payments call `start` makes for a request, if any. -/
def payCall (approve : Bool) (r : StartRequest) : List Call :=
  match rate? r.zone with
  | none => []
  | some rate =>
    let req : AuthorizeRequest := ⟨charge rate r.minutes, "CAD", "tok-test-visa"⟩
    [⟨"payments.authorize", AuthorizeRequest.codec.enc req,
      AuthorizeResponse.codec.enc (authorize approve "auth-77" req)⟩]

def v1Case (id : String) (approve : Bool) (r : StartRequest) : Exchange :=
  { id, given := given approve, request := StartRequest.codec.enc r,
    calls := payCall approve r, response := some (StartResponse.codec.enc (start (env approve) r)) }

def badCase (id : String) (request : Json) : Exchange :=
  { id, given := given true, request, status := 400 }

def startV1Cases : List Exchange := [
  v1Case "one-hour-in-zone-a1" true ⟨"A1", "ABC123", 60⟩,
  v1Case "longest-in-dearest-zone" true ⟨"A1", "ABC123", 240⟩,
  v1Case "shortest-in-cheapest-zone" true ⟨"C3", "Q7", 15⟩,
  v1Case "card-declined" false ⟨"B2", "XYZ9", 30⟩,
  badCase "zero-minutes" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"), ("minutes", 0)]),
  badCase "not-a-step-of-15" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"), ("minutes", 50)]),
  badCase "too-long" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"), ("minutes", 255)]),
  badCase "unknown-zone" (Json.mkObj [("zone", "Z9"), ("plate", "ABC123"), ("minutes", 60)]),
  badCase "lowercase-plate" (Json.mkObj [("zone", "A1"), ("plate", "abc123"), ("minutes", 60)]),
  badCase "minutes-as-string" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"), ("minutes", "60")]),
  -- Rollback evidence: a v1 server refuses what it can't read in full.
  badCase "v2-field-on-v1" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"), ("minutes", 60),
    ("evCharging", true)])]

def envV2 (approve : Bool) (free : Nat) : EnvV2 := { env approve with chargersFree := free }

def v2Case (id : String) (approve : Bool) (free : Nat) (r : StartRequestV2) : Exchange :=
  let queues := r.evCharging == some true && free == 0
  { id, given := given approve [("chargersFree", Lean.toJson free)],
    request := StartRequestV2.codec.enc r,
    calls := if queues then [] else payCall approve ⟨r.zone, r.plate, r.minutes⟩,
    response := some (StartResponseV2.codec.enc (startV2 (envV2 approve free) r)) }

def startV2Cases : List Exchange := [
  v2Case "v1-shaped-request" true 2 ⟨"A1", "ABC123", 60, none⟩,
  v2Case "ev-charger-free" true 2 ⟨"B2", "EV42", 120, some true⟩,
  v2Case "ev-all-chargers-busy" true 0 ⟨"B2", "EV42", 120, some true⟩,
  v2Case "ev-not-wanted" true 0 ⟨"C3", "EV42", 45, some false⟩,
  v2Case "card-declined" false 2 ⟨"A1", "ABC123", 60, some true⟩,
  { (badCase "ev-charging-null" (Json.mkObj [("zone", "A1"), ("plate", "ABC123"),
      ("minutes", 60), ("evCharging", Json.null)])) with given := given true [("chargersFree", 2)] }]

def payCase (id : String) (approve : Bool) (r : AuthorizeRequest) : Exchange :=
  { id, given := Json.mkObj [("card", Json.str (if approve then "approve" else "decline")),
      ("authId", "auth-77")],
    request := AuthorizeRequest.codec.enc r,
    response := some (AuthorizeResponse.codec.enc (authorize approve "auth-77" r)) }

def payBad (id : String) (request : Json) : Exchange :=
  { id, given := Json.mkObj [("card", "approve"), ("authId", "auth-77")], request, status := 400 }

def authorizeCases : List Exchange := [
  payCase "approved" true ⟨500, "CAD", "tok-test-visa"⟩,
  payCase "at-the-limit" true ⟨20000, "USD", "tok-test-visa"⟩,
  payCase "declined" false ⟨500, "CAD", "tok-test-visa"⟩,
  payBad "over-the-limit" (Json.mkObj [("amount", "20001"), ("currency", "CAD"), ("token", "t")]),
  payBad "zero" (Json.mkObj [("amount", "0"), ("currency", "CAD"), ("token", "t")]),
  payBad "amount-as-number" (Json.mkObj [("amount", 500), ("currency", "CAD"), ("token", "t")]),
  payBad "underscore-digits" (Json.mkObj [("amount", "1_000"), ("currency", "CAD"), ("token", "t")]),
  payBad "unknown-currency" (Json.mkObj [("amount", "500"), ("currency", "EUR"), ("token", "t")])]

def schemaFiles : List Export.File :=
  schemas.map fun (n, s) => s.file s!"exported/schemas/{n}.json"

def files : Export.Files := ⟨schemaFiles ++ [
  exchangesFile "payments.authorize" 1 authorizeCases "exported/exchanges/payments.authorize.json",
  exchangesFile "meters.start" 1 startV1Cases "exported/exchanges/meters.start.v1.json",
  exchangesFile "meters.start" 2 startV2Cases "exported/exchanges/meters.start.v2.json"]⟩

#tribrach_write Parking.files

end Parking
