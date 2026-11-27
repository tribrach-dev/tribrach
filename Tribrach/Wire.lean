import Tribrach.Schema

/-!
# Wire codecs: Lean values to JSON and back

A `Codec α` puts three views of one message type side by side: its JSON
Schema shape (`ty`), how a Lean value is written (`enc`), and how JSON is
read back (`dec`). Codecs are built from small pieces, so a message is
described once:

```
def StartRequest.codec : Codec StartRequest :=
  Obj.build StartRequest.mk
    |>.field "zone" (Codec.str (minLen := some 1)) (·.zone)
    |>.field "minutes" (Codec.nat (min := some 15) (max := some 240) (multipleOf := some 15)) (·.minutes)
    |>.codec
```

Every decoder first runs `ty.check` and only then reads the value, so a
decoder accepts exactly what the exported schema accepts, as long as each
piece can read whatever its shape allows. `Codec.agrees` and
`Codec.roundtrips` check both properties on examples; the parking example
runs them on its vectors and on mutated JSON.

The wire mapping lives here, not in the model: field names, optional versus
absent, whole numbers as decimal strings (`Codec.decimal`), and instants as
RFC 3339 text (`Codec.instant`, seconds since 1970 in Lean).
-/

open Lean

namespace Tribrach
namespace Wire

open Schema

/-! ## Instants -/

/-- Days since 1970-01-01 for a proleptic Gregorian date. Months and days
past the end roll over, so 2026-02-30 is 2026-03-02. -/
def daysFromCivil (y m d : Int) : Int :=
  let y := if m ≤ 2 then y - 1 else y
  let era := y / 400
  let yoe := y - era * 400
  let mp := (m + 9) % 12
  let doy := (153 * mp + 2) / 5 + d - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- The (year, month, day) of a day number from `daysFromCivil`. -/
def civilFromDays (z : Int) : Int × Int × Int :=
  let z := z + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  (if m ≤ 2 then yoe + era * 400 + 1 else yoe + era * 400, m, d)

private def pad (width : Nat) (n : Int) : String :=
  let s := toString n.natAbs
  "".pushn '0' (width - s.length) ++ s

/-- The first and last second `Codec.instant` writes: years 0001 to 9999. -/
def instantMin : Int := daysFromCivil 1 1 1 * 86400
def instantMax : Int := daysFromCivil 9999 12 31 * 86400 + 86399

/-- RFC 3339 in UTC, to the second: `2026-11-26T19:30:00Z`. -/
def formatInstant (t : Int) : String :=
  let days := t / 86400
  let secs := t % 86400
  let (y, m, d) := civilFromDays days
  s!"{pad 4 y}-{pad 2 m}-{pad 2 d}T{pad 2 (secs / 3600)}:{pad 2 (secs % 3600 / 60)}:{pad 2 (secs % 60)}Z"

private def num (s : String) (start len : Nat) : Int :=
  (((s.drop start).take len).toString.toNat?.getD 0 : Nat)

/-- Seconds since 1970 for any string `Pat.instant` accepts, after applying
its offset. -/
def parseInstant? (s : String) : Option Int :=
  if !Pat.instant.check s then none else
  let wall := daysFromCivil (num s 0 4) (num s 5 2) (num s 8 2) * 86400
    + num s 11 2 * 3600 + num s 14 2 * 60 + num s 17 2
  if s.length == 20 then some wall  -- ends in Z
  else
    let off := num s 20 2 * 3600 + num s 23 2 * 60
    some (if s.toList[19]? == some '+' then wall - off else wall + off)

/-! ## Codecs -/

/-- A message type's shape, writer and reader. -/
structure Codec (α : Type) where
  ty : Ty
  enc : α → Json
  /-- Reads JSON; `none` when it doesn't have the shape `ty`. -/
  dec : Json → Option α

namespace Codec

/-- A decoder that checks the shape first, then reads. -/
def guarded (ty : Ty) (read : Json → Option α) : Json → Option α :=
  fun j => if ty.check j then read j else none

def bool : Codec Bool where
  ty := .bool
  enc := Json.bool
  dec := guarded .bool fun j => j.getBool?.toOption

def int (min max : Option Int := none) (multipleOf : Option Nat := none) : Codec Int :=
  let ty := Ty.int min max multipleOf
  { ty, enc := fun i => Lean.toJson i,
    dec := guarded ty fun | .num n => asInt? n | _ => none }

/-- A natural number; the minimum is at least 0. -/
def nat (min max : Option Nat := none) (multipleOf : Option Nat := none) : Codec Nat :=
  let ty := Ty.int (some ((min.getD 0 : Nat) : Int)) (max.map fun n => (n : Int)) multipleOf
  { ty, enc := fun n => Lean.toJson n,
    dec := guarded ty fun | .num n => (asInt? n).map Int.toNat | _ => none }

def str (minLen maxLen : Option Nat := none) (pat : Option Pat := none) : Codec String :=
  let ty := Ty.str minLen maxLen pat
  { ty, enc := Json.str, dec := guarded ty fun j => j.getStr?.toOption }

/-- A whole number written as a decimal string, such as money in minor units. -/
def decimal (min max : Option Int := none) : Codec Int :=
  let ty := Ty.decimal min max
  { ty, enc := fun i => Json.str (toString i),
    dec := guarded ty fun j => j.getStr?.toOption >>= String.toInt? }

/-- Seconds since 1970, written as RFC 3339 in UTC. Reading accepts any
offset; writing covers years 0001 to 9999. -/
def instant : Codec Int :=
  let ty := Ty.str (pat := some .instant)
  { ty, enc := fun t => Json.str (formatInstant t),
    dec := guarded ty fun j => j.getStr?.toOption >>= parseInstant? }

/-- One of a fixed set of names, each standing for a value. -/
def enum [BEq α] [Inhabited α] (cases : List (String × α)) : Codec α :=
  let ty := Ty.enum (cases.map (·.1))
  { ty,
    enc := fun a => Json.str ((cases.find? (·.2 == a)).map (·.1) |>.getD ""),
    dec := guarded ty fun j => j.getStr?.toOption >>= fun s => cases.lookup s }

/-- The same JSON read as another type: `f` after reading, `g` before
writing. Round trips need `f (g b) = b`. -/
def map (c : Codec α) (f : α → β) (g : β → α) : Codec β :=
  { ty := c.ty, enc := c.enc ∘ g, dec := fun j => (c.dec j).map f }

/-- Adds a description for people. -/
def doc (text : String) (c : Codec α) : Codec α := { c with ty := .doc text c.ty }

/-- Whether `dec` accepts exactly the JSON that `ty.check` accepts, on these
samples. -/
def agrees (c : Codec α) (samples : List Json) : Bool :=
  samples.all fun j => c.ty.check j == (c.dec j).isSome

/-- Whether writing then reading gives each value back, and what is written
has the shape. -/
def roundtrips [BEq α] (c : Codec α) (values : List α) : Bool :=
  values.all fun a => c.ty.check (c.enc a) && c.dec (c.enc a) == some a

end Codec

/-! ## Objects and tagged unions -/

/-- An object being described field by field. `α` is the message type,
`β` what the fields read so far build (a constructor still waiting for the
rest of its arguments). -/
structure Obj (α β : Type) where
  fields : List (String × Ty × Bool)
  enc : α → List (String × Json)
  /-- Reads the fields; the caller has already checked the shape. -/
  read : Json → Option β

namespace Obj

/-- Start with the constructor. -/
def build (mk : β) : Obj α β := ⟨[], fun _ => [], fun _ => some mk⟩

/-- A required field. -/
def field (o : Obj α (β → γ)) (name : String) (c : Codec β) (get : α → β) : Obj α γ where
  fields := o.fields ++ [req name c.ty]
  enc a := o.enc a ++ [(name, c.enc (get a))]
  read j := do
    let f ← o.read j
    let v ← (j.getObjVal? name).toOption >>= c.dec
    pure (f v)

/-- An optional field: absent when the value is `none`. A JSON `null` is not
absent; it must have the field's shape like any other value. -/
def optional (o : Obj α (Option β → γ)) (name : String) (c : Codec β) (get : α → Option β) :
    Obj α γ where
  fields := o.fields ++ [opt name c.ty]
  enc a := o.enc a ++ ((get a).map (fun v => [(name, c.enc v)])).getD []
  read j := do
    let f ← o.read j
    match j.getObjVal? name with
    | .ok v => pure (f (some (← c.dec v)))
    | .error _ => pure (f none)

/-- The codec for a finished object. -/
def codec (o : Obj α α) : Codec α :=
  let ty := Ty.obj o.fields
  { ty, enc := fun a => Json.mkObj (o.enc a), dec := Codec.guarded ty o.read }

end Obj

/-- One case of a tagged union. -/
structure Case (α : Type) where
  name : String
  fields : List (String × Ty × Bool)
  enc? : α → Option (List (String × Json))
  read : Json → Option α

/-- A case whose fields build a `β`; `proj` picks the case out of an `α`,
`inj` puts it back. -/
def Obj.case (name : String) (o : Obj β β) (proj : α → Option β) (inj : β → α) : Case α where
  name := name
  fields := o.fields
  enc? a := (proj a).map o.enc
  read j := (o.read j).map inj

/-- A case with no fields. -/
def Case.unit (name : String) (is : α → Bool) (val : α) : Case α where
  name := name
  fields := []
  enc? a := if is a then some [] else none
  read _ := some val

/-- A tagged union: the `tag` field names the case. -/
def Codec.tagged (tag : String) (cases : List (Case α)) : Codec α :=
  let ty := Schema.tagged tag (cases.map fun c => (c.name, c.fields))
  { ty,
    enc := fun a =>
      match cases.findSome? (fun c => (c.enc? a).map (c.name, ·)) with
      | some (n, kvs) => Json.mkObj ((tag, Json.str n) :: kvs)
      | none => Json.null,
    dec := Codec.guarded ty fun j => do
      let n ← (j.getObjValAs? String tag).toOption
      let c ← cases.find? (·.name == n)
      c.read j }

/-! ## Exchanges

`tribrach.exchanges.v1` records what a service does with real messages, for
hosts to replay against their handlers: what the server is given besides the
request (`given`: a clock, ids, stubbed answers), the request, the calls it
makes to other services with their answers, and the HTTP status and response.
A status of 400 means the request doesn't decode; such cases have no calls
and no response. Hosts compare responses with the JSON equality of
`tests/conformance/replay.json`.
-/

/-- A call to another service, with the answer it got. -/
structure Call where
  contract : String
  request : Json
  response : Json

structure Exchange where
  id : String
  given : Json := Json.mkObj []
  request : Json
  status : Nat := 200
  calls : List Call := []
  response : Option Json := none

def Exchange.toJson (x : Exchange) : Json :=
  Json.mkObj ([("id", Json.str x.id), ("given", x.given), ("request", x.request),
    ("status", Lean.toJson x.status),
    ("calls", Json.arr (x.calls.map fun c => Json.mkObj [("contract", Json.str c.contract),
      ("request", c.request), ("response", c.response)]).toArray)]
    ++ (x.response.map fun r => [("response", r)]).getD [])

/-- The exchanges of one contract version, as a file to export. -/
def exchangesFile (contract : String) (version : Nat) (cases : List Exchange) (path : String) :
    Export.File :=
  { path, text := Schema.renderJson (Json.mkObj [
      ("format", Json.str "tribrach.exchanges.v1"), ("contract", Json.str contract),
      ("version", Lean.toJson version),
      ("cases", Json.arr (cases.map Exchange.toJson).toArray)])
      ["format", "contract", "version", "cases", "id", "given", "request", "status", "calls",
       "response"] ++ "\n" }

section Checks
#guard formatInstant 0 == "1970-01-01T00:00:00Z"
#guard formatInstant 1795721362 == "2026-11-26T19:29:22Z"
#guard parseInstant? "2026-11-26T11:29:22-08:00" == some 1795721362
#guard parseInstant? "2026-11-27T00:59:22+05:30" == some 1795721362
#guard parseInstant? "2026-02-30T00:00:00Z" == parseInstant? "2026-03-02T00:00:00Z"
#guard parseInstant? "2026-11-26T19:29:22.5Z" == none
#guard formatInstant instantMin == "0001-01-01T00:00:00Z"
#guard formatInstant instantMax == "9999-12-31T23:59:59Z"
#guard formatInstant (-1) == "1969-12-31T23:59:59Z"
-- Every 997,331 seconds from year 1 to 9999 (about 316,000 instants).
#guard (List.range ((instantMax - instantMin).toNat / 997331 + 1)).all fun i =>
  let t := instantMin + 997331 * i
  parseInstant? (formatInstant t) == some t
#guard Codec.decimal.dec "9007199254740993" == some 9007199254740993
#guard Codec.decimal.dec "1_000" == none
end Checks

end Wire
end Tribrach
