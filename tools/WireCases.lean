import Tribrach.Wire
import Std.Time

/-!
Writes and checks `tests/conformance/wire.json`: how each wire primitive
reads and writes JSON, as `Tribrach.Wire` does it.

Each case gives a JSON Schema (exactly as `Ty.toJson` exports it, which is
what instruments generate code from), an input as JSON text, and either the
JSON the codec writes back after reading it, or that reading fails. Inputs are
text, not JSON values, so cases can say `2.0`, `1e2`, a duplicated key or a
trailing comma.

From the repository root:

* `lake env lean --run tools/WireCases.lean` checks the committed file;
* `lake env lean --run tools/WireCases.lean write` rewrites it.

Every case also checks, in Lean, that the decoder accepts exactly what the
schema accepts (`Codec.agrees`) and that what it writes reads back the same.
The check also compares core's calendar rule with Lean's `Std.Time` over a
400-year era, as an independent second opinion on which days exist.
-/

open Lean Tribrach Schema Wire

/-- A codec with its type forgotten, so cases of any type sit in one list. -/
structure AnyCodec where
  ty : Ty
  /-- Read then write: `none` when reading fails. -/
  canon : Json → Option Json
  /-- Writing then reading gives the same JSON back. -/
  stable : Json → Bool

def AnyCodec.of (c : Codec α) : AnyCodec where
  ty := c.ty
  canon j := (c.dec j).map c.enc
  stable j := match c.dec j with
    | some a => c.ty.check (c.enc a) && ((c.dec (c.enc a)).map c.enc) == some (c.enc a)
    | none => true

structure Case where
  id : String
  codec : AnyCodec
  input : String

def Case.output (c : Case) : Option Json :=
  match Json.parse c.input with
  | .ok j => c.codec.canon j
  | .error _ => none

/-- Problems with a case in Lean itself: the decoder and the schema disagree,
or a written value doesn't read back. -/
def Case.problems (c : Case) : List String :=
  match Json.parse c.input with
  | .error _ => []
  | .ok j =>
    (if c.codec.ty.check j == (c.codec.canon j).isSome then [] else
      [s!"{c.id}: the decoder and the schema disagree"]) ++
    (if c.codec.stable j then [] else [s!"{c.id}: what is written doesn't read back"])

def Case.toJson (c : Case) : Json :=
  Json.mkObj ([("id", Json.str c.id), ("schema", c.codec.ty.toJson), ("input", Json.str c.input)]
    ++ match c.output with
      | some o => [("output", o)]
      | none => [("error", Json.bool true)])

/-! ## Cases -/

def cases (pre : String) (c : AnyCodec) (xs : List (String × String)) : List Case :=
  xs.map fun (id, input) => { id := pre ++ "." ++ id, codec := c, input }

structure Point where
  x : Int
  label : Option String
  deriving BEq

def Point.codec : Codec Point :=
  Obj.build Point.mk
    |>.field "x" (Codec.int (min := some 0) (max := some 9)) (·.x)
    |>.optional "label" (Codec.str) (·.label)
    |>.codec

inductive Shape where
  | dot
  | box (w : Int)
  deriving BEq

structure Box where
  w : Int

def Shape.codec : Codec Shape :=
  Codec.tagged "kind" [
    Case.unit "dot" (· == .dot) .dot,
    (Obj.build Box.mk |>.field "w" (Codec.int) (·.w)).case "box"
      (fun | .box w => some ⟨w⟩ | _ => none) (fun b => .box b.w)]

structure Charge where
  amount : Int
  at_ : Int
  note : Option String

def Charge.codec : Codec Charge :=
  Obj.build Charge.mk
    |>.field "amount" (Codec.decimal (min := some 1)) (·.amount)
    |>.field "at" Codec.instant (·.at_)
    |>.optional "note" (Codec.str (maxLen := some 3)) (·.note)
    |>.codec

inductive Color where
  | red
  | green
  deriving BEq, Inhabited

/-- A constant string field, such as a version marker. -/
def constV1 : Codec Unit where
  ty := .constStr "v1"
  enc _ := Json.str "v1"
  dec := Codec.guarded (.constStr "v1") fun _ => some ()

/-- One or two whole numbers. -/
def ints : Codec (List Int) :=
  let ty := Ty.arr (Ty.int) (minItems := some 1) (maxItems := some 2)
  { ty, enc := fun xs => Json.arr (xs.map Lean.toJson).toArray,
    dec := Codec.guarded ty fun j => j.getArr?.toOption >>= fun a => a.toList.mapM fun
      | .num n => asInt? n
      | _ => none }

def all : List Case :=
  cases "bool" (.of Codec.bool) [
    ("true", "true"), ("false", "false"), ("string", "\"true\""), ("number", "1"),
    ("null", "null")] ++
  cases "int" (.of (Codec.int)) [
    ("zero", "0"), ("negative", "-12"), ("whole-fraction", "2.0"), ("exponent", "1e2"),
    ("negative-zero", "-0"), ("fraction", "2.5"), ("small-exponent", "25e-1"),
    ("int64-max", "9223372036854775807"), ("int64-min", "-9223372036854775808"),
    ("beyond-double", "9007199254740993"), ("string", "\"1\""), ("bool", "true"),
    ("null", "null")] ++
  cases "int-bounded" (.of (Codec.int (min := some 0) (max := some 9))) [
    ("min", "0"), ("max", "9"), ("below", "-1"), ("above", "10"), ("max-as-fraction", "9.0")] ++
  cases "int-multiple" (.of (Codec.int (multipleOf := some 15))) [
    ("multiple", "45"), ("zero", "0"), ("negative-multiple", "-30"), ("not-multiple", "50")] ++
  cases "str" (.of (Codec.str)) [
    ("empty", "\"\""), ("plain", "\"hello\""), ("escapes", "\"a\\\"b\\\\c\\n\""),
    ("unicode-escape", "\"\\u00e9\""), ("surrogate-pair", "\"\\ud83d\\ude00\""),
    ("number", "1"), ("null", "null")] ++
  cases "str-length" (.of (Codec.str (minLen := some 1) (maxLen := some 3))) [
    ("empty", "\"\""), ("one", "\"a\""), ("three", "\"abc\""), ("four", "\"abcd\""),
    ("accents-count-once", "\"éé\""), ("emoji-count-once", "\"😀😀😀\""),
    ("four-emoji", "\"😀😀😀😀\"")] ++
  cases "str-pattern" (.of (Codec.str (pat := some .slug))) [
    ("ok", "\"a-b\""), ("leading-dash", "\"-a\""), ("upper", "\"A\"")] ++
  cases "const" (.of constV1) [
    ("same", "\"v1\""), ("other", "\"v2\"")] ++
  cases "enum" (.of (Codec.enum [("red", Color.red), ("green", Color.green)])) [
    ("red", "\"red\""), ("green", "\"green\""), ("unknown", "\"blue\""),
    ("case-differs", "\"Red\""), ("number", "0")] ++
  cases "decimal" (.of (Codec.decimal)) [
    ("zero", "\"0\""), ("negative", "\"-12\""), ("beyond-double", "\"9007199254740993\""),
    ("int64-max", "\"9223372036854775807\""), ("negative-zero", "\"-0\""),
    ("leading-zero", "\"007\""), ("plus", "\"+5\""), ("underscore", "\"1_000\""),
    ("fraction", "\"3.0\""), ("exponent", "\"1e3\""), ("space", "\" 5\""),
    ("number", "5"), ("empty", "\"\"")] ++
  cases "decimal-bounded" (.of (Codec.decimal (min := some 1) (max := some 20000))) [
    ("min", "\"1\""), ("max", "\"20000\""), ("below", "\"0\""), ("above", "\"20001\"")] ++
  cases "instant" (.of Codec.instant) [
    ("utc", "\"2026-11-26T19:29:22Z\""), ("west", "\"2026-11-26T11:29:22-08:00\""),
    ("east-half-hour", "\"2026-11-27T00:59:22+05:30\""),
    ("zero-offset", "\"2026-11-26T19:29:22+00:00\""),
    ("leap-day", "\"2028-02-29T12:00:00Z\""), ("leap-century", "\"2000-02-29T00:00:00Z\""),
    ("february-30", "\"2026-02-30T00:00:00Z\""), ("not-a-leap-year", "\"2026-02-29T00:00:00Z\""),
    ("century-not-leap", "\"1900-02-29T00:00:00Z\""), ("april-31", "\"2026-04-31T00:00:00Z\""),
    ("day-00", "\"2026-11-00T00:00:00Z\""), ("month-end-west", "\"2026-04-30T23:30:00-08:00\""),
    ("year-one", "\"0001-01-01T00:00:00Z\""), ("year-9999", "\"9999-12-31T23:59:59Z\""),
    ("before-1970", "\"1969-12-31T23:59:59Z\""),
    ("fraction", "\"2026-11-26T19:29:22.5Z\""), ("lowercase", "\"2026-11-26t19:29:22z\""),
    ("hour-24", "\"2026-11-26T24:00:00Z\""), ("second-60", "\"2026-12-31T23:59:60Z\""),
    ("month-13", "\"2026-13-01T00:00:00Z\""), ("day-32", "\"2026-01-32T00:00:00Z\""),
    ("no-offset", "\"2026-11-26T19:29:22\""), ("space", "\"2026-11-26 19:29:22Z\""),
    ("number", "1795721362")] ++
  cases "array" (.of ints) [
    ("one", "[1]"), ("two", "[1, 2.0]"), ("empty", "[]"), ("three", "[1, 2, 3]"),
    ("wrong-item", "[1, \"2\"]"), ("not-array", "1")] ++
  cases "object" (.of Point.codec) [
    ("required-only", "{\"x\": 1}"), ("with-optional", "{\"x\": 1, \"label\": \"a\"}"),
    ("key-order", "{\"label\": \"a\", \"x\": 1}"), ("whole-fraction", "{\"x\": 3.0}"),
    ("missing-required", "{\"label\": \"a\"}"), ("unknown-key", "{\"x\": 1, \"y\": 2}"),
    ("null-is-not-absent", "{\"x\": 1, \"label\": null}"), ("field-out-of-range", "{\"x\": 10}"),
    ("duplicate-key", "{\"x\": 1, \"x\": 2}"), ("array", "[]"), ("null", "null")] ++
  cases "tagged" (.of Shape.codec) [
    ("unit-case", "{\"kind\": \"dot\"}"), ("fields-case", "{\"kind\": \"box\", \"w\": 2.0}"),
    ("missing-field", "{\"kind\": \"box\"}"), ("extra-field", "{\"kind\": \"dot\", \"w\": 2}"),
    ("unknown-case", "{\"kind\": \"ring\"}"), ("no-tag", "{\"w\": 2}"),
    ("tag-not-string", "{\"kind\": 1}")] ++
  cases "nested" (.of Charge.codec) [
    ("canonical", "{\"amount\": \"500\", \"at\": \"2026-11-26T19:29:22Z\"}"),
    ("rewritten", "{\"at\": \"2026-11-26T11:29:22-08:00\", \"amount\": \"500\", \"note\": \"ok\"}"),
    ("amount-as-number", "{\"amount\": 500, \"at\": \"2026-11-26T19:29:22Z\"}"),
    ("bad-instant", "{\"amount\": \"500\", \"at\": \"2026-11-26T19:29:22.5Z\"}"),
    ("note-too-long", "{\"amount\": \"500\", \"at\": \"2026-11-26T19:29:22Z\", \"note\": \"long\"}")] ++
  cases "text" (.of Point.codec) [
    ("whitespace", " \n\t{ \"x\" : 1 } \n"), ("trailing-comma", "{\"x\": 1,}"),
    ("trailing-data", "{\"x\": 1} {}"), ("single-quotes", "{'x': 1}"), ("empty", ""),
    ("leading-plus", "{\"x\": +1}"), ("leading-zero", "{\"x\": 01}"),
    ("bare-dot", "{\"x\": 1.}"), ("nan", "{\"x\": NaN}")]

def about : String :=
  "How each wire primitive reads and writes JSON (Tribrach.Wire). Each case has a JSON Schema " ++
  "as core exports it, an input as JSON text, and either output, the JSON the codec writes " ++
  "after reading the input, or error: true when reading fails. Instruments parse the input with " ++
  "their own JSON parser, read it as the schema says, write it back and compare with output " ++
  "by the JSON equality of replay.json. Reading fails on text that isn't one JSON value " ++
  "(trailing data, a trailing comma, NaN) and on an object with a duplicated key. Whole numbers " ++
  "may be written 2.0 or 1e2 and are written back plainly; instants are written back in UTC, " ++
  "and an instant whose day doesn't exist in its month (30 February, 29 February outside leap years) fails. " ++
  "Cases stay within signed 64-bit integers."

def file : String :=
  renderJson (Json.mkObj [("format", Json.str "tribrach.conformance.wire.v1"),
      ("about", Json.str about), ("cases", Json.arr (all.map Case.toJson).toArray)])
    (["format", "about", "cases", "id", "schema", "input", "output", "error"] ++ keyOrder) ++ "\n"

def path : System.FilePath := "tests" / "conformance" / "wire.json"

/-- A second opinion on the calendar from Lean's standard library: over one
400-year era (2000 to 2399) and every month and day number 1 to 31,
`Pat.daysInMonth` and `Std.Time` agree on which days exist. -/
def calendarDisagreements : List String :=
  (List.range 400).flatMap fun i => (List.finRange 12).flatMap fun mi => (List.finRange 31).filterMap fun di =>
    let y := 2000 + i
    let ours := decide (di.val + 1 ≤ Pat.daysInMonth y (mi.val + 1))
    let month := Std.Time.Month.Ordinal.ofInt (mi.val + 1) (by have := mi.isLt; omega)
    let day := Std.Time.Day.Ordinal.ofInt (di.val + 1) (by have := di.isLt; omega)
    let std := (Std.Time.PlainDate.ofYearMonthDay? (Int.ofNat y) month day).isSome
    if ours == std then none
    else some s!"{y}-{mi.val + 1}-{di.val + 1}: Tribrach says {ours}, Std.Time says {std}"

def main (args : List String) : IO UInt32 := do
  let problems := all.flatMap Case.problems ++ calendarDisagreements
  let dups := all.map (·.id) |>.filter fun i => (all.filter (·.id == i)).length > 1
  for p in problems ++ dups.map (s!"duplicate case id {·}") do IO.println s!"FAIL {p}"
  if !problems.isEmpty || !dups.isEmpty then return 1
  if args == ["write"] then
    IO.FS.writeFile path file
    IO.println s!"wrote {path}: {all.length} cases"
    return 0
  let committed ← IO.FS.readFile path
  if committed != file then
    IO.println s!"FAIL {path} is stale; run lake env lean --run tools/WireCases.lean write"
    return 1
  IO.println s!"ok   {path}: {all.length} cases match Tribrach.Wire"
  return 0
