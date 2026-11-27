import Lean.Data.Json
import Tribrach.Export
import Tribrach.Pattern

/-!
# Schemas: JSON types described in Lean

A `Schema` describes a JSON document: its shape (`Ty`) and the rules that a
shape can't say, such as "ranges don't overlap". From one description Tribrach
gets two things that agree by construction:

* `Schema.toJson`: a JSON Schema (draft 2020-12) for other tools. Rules go in
  an `x-tribrach` field, by Lean name and stamp, since JSON Schema can't run
  them.
* `Schema.accepts`: a checker in Lean, the one proofs talk about.

Patterned strings use a closed list of patterns (`Pat`). Each one is a pattern
tree (`Tribrach.Re`); the regular expression for the schema and the Lean
checker are both read off it, and `tests/conformance/patterns.json` exports
the tree so instruments run one generic matcher, and nobody writes a regex of
their own.
-/

open Lean

namespace Tribrach
namespace Schema

/-- The patterns a string field may require. -/
inductive Pat where
  /-- Exactly `n` lowercase hex digits. -/
  | hex (n : Nat)
  /-- Lowercase letters, digits and `-`, not starting with `-`. -/
  | slug
  /-- Uppercase ASCII letters and digits, at least one. -/
  | upperAlnum
  /-- `owner/name`, each part made of letters, digits, `_`, `.` and `-`. -/
  | ownerRepo
  /-- A relative path with `/` separators: no leading `/`, no `..` segment,
  no backslash, no control characters, no line or paragraph separators. -/
  | relPath
  /-- A URI: a scheme, `:`, then no spaces or control characters. -/
  | uri
  /-- An RFC 3339 date-time with uppercase `T` and `Z`, such as
  `2026-11-26T19:30:00Z` or `2026-11-26T11:30:00.5-08:00`. Only the shape is
  checked, not the calendar. -/
  | dateTime
  /-- An RFC 3339 instant to the second: like `dateTime` but with no
  fraction, and with each field in range (month 01-12, day 01-31, hour 00-23,
  minute and second 00-59, offset up to 23:59). The day isn't checked against
  the month, so `2026-02-30` passes and decodes to 2 March. -/
  | instant
  /-- A whole number written as a decimal string, for values JSON numbers
  can't carry safely (money, 64-bit ids): `0` or an optional `-` then digits
  with no leading zero. `-0` is not allowed. -/
  | decimal
  deriving Repr, BEq, Inhabited

namespace Pat

open Re in
/-- The pattern as a tree (`Tribrach.Re`): the source of truth. `regex` and
`check` are both read off it, and `tests/conformance/patterns.json` carries
it to instruments and adapters. -/
def tree : Pat → Re
  | hex n => exactly n (set [.range '0' '9', .range 'a' 'f'])
  | slug => seq [set [.range 'a' 'z', .range '0' '9'], many (set [.range 'a' 'z', .range '0' '9', .char '-'])]
  | upperAlnum => many1 (set [.range 'A' 'Z', .range '0' '9'])
  | ownerRepo =>
    let part := many1 (set [.range 'A' 'Z', .range 'a' 'z', .range '0' '9', .char '_', .char '.', .char '-'])
    seq [part, lit "/", part]
  | relPath =>
    without (many1 (set [.char '\\', .range '\x00' '\x1f', .char '\u2028', .char '\u2029'] (negated := true)))
      [.startsWith "/", .segment '/' ".."]
  | uri =>
    seq [set [.range 'A' 'Z', .range 'a' 'z'],
      many (set [.range 'A' 'Z', .range 'a' 'z', .range '0' '9', .char '+', .char '.', .char '-']),
      lit ":", many (set [.range '\x00' '\x20', .char '\x7f'] (negated := true))]
  | dateTime =>
    let d2 := exactly 2 digit
    seq [exactly 4 digit, lit "-", d2, lit "-", d2, lit "T", d2, lit ":", d2, lit ":", d2,
      opt (seq [lit ".", many1 digit]),
      alt [lit "Z", seq [set [.char '+', .char '-'], d2, lit ":", d2]]]
  | instant =>
    let d : Re := set [.range '0' '9']
    let d05 : Re := set [.range '0' '5']
    let hour := alt [seq [set [.char '0', .char '1'], d], seq [lit "2", set [.range '0' '3']]]
    seq [exactly 4 digit, lit "-",
      alt [seq [lit "0", set [.range '1' '9']], seq [lit "1", set [.range '0' '2']]], lit "-",
      alt [seq [lit "0", set [.range '1' '9']], seq [set [.char '1', .char '2'], d], seq [lit "3", set [.char '0', .char '1']]],
      lit "T", hour, lit ":", d05, d, lit ":", d05, d,
      alt [lit "Z", seq [set [.char '+', .char '-'], hour, lit ":", d05, d]]]
  | decimal => alt [lit "0", seq [opt (lit "-"), set [.range '1' '9'], many digit]]

/-- The regular expression, in the syntax JSON Schema uses (ECMA-262). -/
def regex (p : Pat) : String := p.tree.toRegex

-- The trees render to the regexes the schema has always published.
#guard (hex 16).regex == "^[0-9a-f]{16}$"
#guard slug.regex == "^[a-z0-9][a-z0-9-]*$"
#guard upperAlnum.regex == "^[A-Z0-9]+$"
#guard ownerRepo.regex == "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
#guard relPath.regex == "^(?!/)(?!.*(^|/)\\.\\.(/|$))[^\\\\\\x00-\\x1f\\u2028\\u2029]+$"
#guard uri.regex == "^[A-Za-z][A-Za-z0-9+.-]*:[^\\x00-\\x20\\x7f]*$"
#guard dateTime.regex ==
  "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"
#guard instant.regex ==
  "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
#guard decimal.regex == "^(0|-?[1-9][0-9]*)$"

/-- A JSON Schema `format` to add beside the pattern, for tools that use it. -/
def format? : Pat → Option String
  | uri => some "uri"
  | dateTime => some "date-time"
  | instant => some "date-time"
  | _ => none

/-- The name conformance cases use. -/
def name : Pat → String
  | hex n => "hex" ++ toString n
  | slug => "slug"
  | upperAlnum => "upperAlnum"
  | ownerRepo => "ownerRepo"
  | relPath => "relPath"
  | uri => "uri"
  | dateTime => "dateTime"
  | instant => "instant"
  | decimal => "decimal"

/-- The Lean side of each pattern, read off the tree. -/
def check (p : Pat) : String → Bool := p.tree.accepts

/-- Every pattern conformance covers. -/
def all : List Pat :=
  [hex 16, hex 40, hex 64, slug, upperAlnum, ownerRepo, relPath, uri, dateTime, instant, decimal]

end Pat

/-- The shape of a JSON value. Objects are closed: a key the type doesn't
name is an error. -/
inductive Ty where
  | bool
  /-- A whole number; JSON numbers like `2.0` count. -/
  | int (min : Option Int := none) (max : Option Int := none) (multipleOf : Option Nat := none)
  /-- A whole number written as a decimal string (`Pat.decimal`). JSON Schema
  can't bound a string's value, so the bounds go under `x-tribrach`. -/
  | decimal (min : Option Int := none) (max : Option Int := none)
  /-- A string; lengths count Unicode code points. -/
  | str (minLen : Option Nat := none) (maxLen : Option Nat := none) (pat : Option Pat := none)
  | constInt (n : Int)
  | constStr (s : String)
  /-- One of these strings. -/
  | enum (values : List String)
  | arr (item : Ty) (minItems : Option Nat := none) (maxItems : Option Nat := none)
  /-- Fields as (name, type, required). -/
  | obj (fields : List (String × Ty × Bool))
  /-- Exactly one of these. With `tagged`, the alternatives are objects told
  apart by a constant field, so at most one can match. -/
  | oneOf (alts : List Ty)
  /-- A description for people; it doesn't change what is accepted. -/
  | doc (text : String) (ty : Ty)
  deriving Inhabited

/-- A required field. -/
def req (name : String) (ty : Ty) : String × Ty × Bool := (name, ty, true)
/-- An optional field. -/
def opt (name : String) (ty : Ty) : String × Ty × Bool := (name, ty, false)

/-- A tagged union: each case is an object whose `tag` field holds the
case's name. -/
def tagged (tag : String) (cases : List (String × List (String × Ty × Bool))) : Ty :=
  .oneOf (cases.map fun (n, fs) => .obj (req tag (.constStr n) :: fs))

private def optField (k : String) : Option Json → List (String × Json)
  | some v => [(k, v)]
  | none => []

/-- A JSON number as a whole number, if it is one. -/
def asInt? (n : JsonNumber) : Option Int :=
  let p : Int := (10 ^ n.exponent : Nat)
  if n.mantissa % p == 0 then some (n.mantissa / p) else none

mutual
/-- The JSON Schema for a type. -/
def Ty.toJson : Ty → Json
  | .bool => Json.mkObj [("type", Json.str "boolean")]
  | .int lo hi m => Json.mkObj ([("type", Json.str "integer")] ++ optField "minimum" (lo.map Lean.toJson)
      ++ optField "maximum" (hi.map Lean.toJson) ++ optField "multipleOf" (m.map Lean.toJson))
  | .decimal lo hi => Json.mkObj ([("type", Json.str "string"),
      ("pattern", Json.str Pat.decimal.regex)]
      ++ (if lo.isNone && hi.isNone then [] else
        [("x-tribrach", Json.mkObj (optField "minimum" (lo.map Lean.toJson)
          ++ optField "maximum" (hi.map Lean.toJson)))]))
  | .str lo hi p => Json.mkObj ([("type", Json.str "string")] ++ optField "minLength" (lo.map Lean.toJson)
      ++ optField "maxLength" (hi.map Lean.toJson)
      ++ optField "pattern" (p.map (Json.str ·.regex))
      ++ optField "format" ((p.bind Pat.format?).map Json.str))
  | .constInt n => Json.mkObj [("const", Lean.toJson n)]
  | .constStr s => Json.mkObj [("const", Json.str s)]
  | .enum vs => Json.mkObj [("enum", Json.arr (vs.map Json.str).toArray)]
  | .arr t lo hi => Json.mkObj ([("type", Json.str "array"), ("items", t.toJson)]
      ++ optField "minItems" (lo.map Lean.toJson) ++ optField "maxItems" (hi.map Lean.toJson))
  | .obj fs =>
    let required := fs.filterMap fun (n, _, r) => if r then some (Json.str n) else none
    Json.mkObj ([("type", Json.str "object"), ("additionalProperties", Json.bool false)]
      ++ (if required.isEmpty then [] else [("required", Json.arr required.toArray)])
      ++ [("properties", Json.mkObj (Ty.fieldsJson fs))])
  | .oneOf alts => Json.mkObj [("oneOf", Json.arr (Ty.altsJson alts).toArray)]
  | .doc d t => t.toJson.setObjVal! "description" (Json.str d)

def Ty.altsJson : List Ty → List Json
  | [] => []
  | t :: rest => t.toJson :: Ty.altsJson rest

def Ty.fieldsJson : List (String × Ty × Bool) → List (String × Json)
  | [] => []
  | (n, t, _) :: rest => (n, t.toJson) :: Ty.fieldsJson rest
end

mutual
/-- Whether a JSON value has this type. -/
def Ty.check : Ty → Json → Bool
  | .bool, .bool _ => true
  | .int lo hi m, .num n =>
    match asInt? n with
    | some i => lo.all (· ≤ i) && hi.all (i ≤ ·) && m.all (fun m => i % (m : Int) == 0)
    | none => false
  | .decimal lo hi, .str s =>
    Pat.decimal.check s &&
      (match s.toInt? with
       | some i => lo.all (· ≤ i) && hi.all (i ≤ ·)
       | none => false)
  | .str lo hi p, .str s =>
    lo.all (· ≤ s.length) && hi.all (s.length ≤ ·) && p.all (·.check s)
  | .constInt n, .num m => asInt? m == some n
  | .constStr s, .str t => s == t
  | .enum vs, .str s => vs.contains s
  | .arr t lo hi, .arr xs =>
    lo.all (· ≤ xs.size) && hi.all (xs.size ≤ ·) && Ty.checkItems t xs.toList
  | .obj fs, .obj kvs =>
    kvs.all (fun k _ => fs.any (·.1 == k)) && Ty.checkFields fs (.obj kvs)
  | .oneOf alts, j => Ty.countMatches alts j == 1
  | .doc _ t, j => t.check j
  | _, _ => false

def Ty.countMatches : List Ty → Json → Nat
  | [], _ => 0
  | t :: rest, j => (if t.check j then 1 else 0) + Ty.countMatches rest j

def Ty.checkItems (t : Ty) : List Json → Bool
  | [] => true
  | x :: xs => t.check x && Ty.checkItems t xs

def Ty.checkFields : List (String × Ty × Bool) → Json → Bool
  | [], _ => true
  | (n, t, r) :: rest, j =>
    (match j.getObjVal? n with
     | .ok v => t.check v
     | .error _ => !r) && Ty.checkFields rest j
end

/-- A rule the shape can't say, checked on the whole document. `lean` names
the Lean definition that states it; its stamp goes into the schema, so the
schema changes when the rule does. -/
structure Rule where
  lean : Export.LeanRef
  doc : String
  check : Json → Bool

/-- A JSON document type: its shape plus its rules. -/
structure Schema where
  /-- The schema's `$id`. -/
  id : String
  title : String
  description : Option String := none
  root : Ty
  rules : List Rule := []

/-- The JSON Schema. -/
def Schema.toJson (s : Schema) : Json :=
  let base := s.root.toJson
    |>.setObjVal! "$schema" (Json.str "https://json-schema.org/draft/2020-12/schema")
    |>.setObjVal! "$id" (Json.str s.id)
    |>.setObjVal! "title" (Json.str s.title)
  let base := match s.description with
    | some d => base.setObjVal! "description" (Json.str d)
    | none => base
  if s.rules.isEmpty then base
  else base.setObjVal! "x-tribrach" (Json.mkObj [("rules", Json.arr (s.rules.map fun r =>
    Json.mkObj [("lean", Json.str r.lean.name), ("stamp", Json.str r.lean.stamp),
      ("doc", Json.str r.doc)]).toArray)])

/-- Keys in the order people read a schema; other keys (property names)
follow alphabetically. -/
def keyOrder : List String :=
  ["$schema", "$id", "title", "description", "type", "const", "enum", "minimum", "maximum",
   "multipleOf", "minLength", "maxLength", "pattern", "format", "minItems", "maxItems", "items",
   "oneOf",
   "additionalProperties", "required", "properties", "x-tribrach", "rules", "lean", "stamp", "doc"]

private def entries (order : List String) (kvs : Std.TreeMap.Raw String Json compare) :
    Array (String × Json) :=
  let rank (k : String) := (order.idxOf? k).getD order.length
  (kvs.foldl (fun acc k v => acc.push (k, v)) #[]).qsort fun a b =>
    rank a.1 < rank b.1 || (rank a.1 == rank b.1 && a.1 < b.1)

/-- One line, keys in `order`. -/
partial def oneLine (order : List String) : Json → String
  | .arr xs => "[" ++ ", ".intercalate (xs.toList.map (oneLine order)) ++ "]"
  | .obj kvs =>
    let es := entries order kvs
    if es.isEmpty then "{}"
    else "{ " ++ ", ".intercalate (es.toList.map fun (k, v) =>
      (Json.str k).compress ++ ": " ++ oneLine order v) ++ " }"
  | j => j.compress

/-- Two-space indented JSON, keys in `order` (others alphabetically after),
short values on one line. -/
partial def renderJson (j : Json) (order : List String := keyOrder) (indent : String := "") :
    String :=
  let flat := oneLine order j
  if indent.length + flat.length ≤ 96 then flat else
  let inner := indent ++ "  "
  match j with
  | .arr xs => "[\n" ++ ",\n".intercalate (xs.toList.map fun x => inner ++ renderJson x order inner)
      ++ "\n" ++ indent ++ "]"
  | .obj kvs => "{\n" ++ ",\n".intercalate ((entries order kvs).toList.map fun (k, v) =>
      inner ++ (Json.str k).compress ++ ": " ++ renderJson v order inner) ++ "\n" ++ indent ++ "}"
  | _ => flat

def Schema.render (s : Schema) : String := renderJson s.toJson ++ "\n"

/-- What is wrong with a document: the shape first, then each broken rule by
Lean name. Empty means accepted. -/
def Schema.problems (s : Schema) (j : Json) : List String :=
  if !s.root.check j then ["does not match the schema " ++ s.id]
  else (s.rules.filter (!·.check j)).map (·.lean.name)

def Schema.accepts (s : Schema) (j : Json) : Bool := (s.problems j).isEmpty

/-- The schema as a file to export. -/
def Schema.file (s : Schema) (path : String) : Export.File :=
  { path, text := s.render }

section Checks
-- Small checks of the checker's edge cases, run on every build.
private def point : Ty := .obj [req "x" (.int (min := some 0) (max := some 9)), opt "label" (.str)]
#guard point.check (Json.mkObj [("x", Json.num ⟨20, 1⟩)])  -- 2.0 is a whole number
#guard !point.check (Json.mkObj [("x", Json.num ⟨25, 1⟩)]) -- 2.5 is not
#guard !point.check (Json.mkObj [("x", 10)])
#guard !point.check (Json.mkObj [("label", "a")])           -- x is required
#guard !point.check (Json.mkObj [("x", 1), ("y", 2)])       -- objects are closed
#guard point.check (Json.mkObj [("x", 1), ("label", "a")])
#guard !point.check (Json.mkObj [("x", 1), ("label", Json.null)]) -- null is not absent
#guard !(Ty.constInt 1).check (Json.bool true)
#guard (Ty.str (maxLen := some 2)).check "éé"              -- code points, not bytes
#guard !(Ty.arr .bool (minItems := some 1)).check (Json.arr #[])
#guard (Ty.int (multipleOf := some 15)).check (Json.num 45)
#guard !(Ty.int (multipleOf := some 15)).check (Json.num 50)
#guard (Ty.decimal (min := some 1) (max := some 20000)).check "350"
#guard !(Ty.decimal (min := some 1) (max := some 20000)).check "0"
#guard !(Ty.decimal (min := some 1)).check "1_000"         -- toInt? alone would take it
#guard !(Ty.decimal).check (Json.num 3)
private def shape : Ty := tagged "kind" [("dot", []), ("box", [req "w" (.int)])]
#guard shape.check (Json.mkObj [("kind", "dot")])
#guard shape.check (Json.mkObj [("kind", "box"), ("w", 2)])
#guard !shape.check (Json.mkObj [("kind", "box")])
#guard !shape.check (Json.mkObj [("kind", "dot"), ("w", 2)])
#guard !shape.check (Json.mkObj [("kind", "ring")])
end Checks

end Schema
end Tribrach
