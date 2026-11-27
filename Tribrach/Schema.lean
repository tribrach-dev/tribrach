import Lean.Data.Json
import Tribrach.Export

/-!
# Schemas: JSON types described in Lean

A `Schema` describes a JSON document: its shape (`Ty`) and the rules that a
shape can't say, such as "ranges don't overlap". From one description Tribrach
gets two things that agree by construction:

* `Schema.toJson`: a JSON Schema (draft 2020-12) for other tools. Rules go in
  an `x-tribrach` field, by Lean name and stamp, since JSON Schema can't run
  them.
* `Schema.accepts`: a checker in Lean, the one proofs talk about.

Patterned strings use a closed list of patterns (`Pat`). Each one has a
regular expression for the schema and a Lean function for the checker, and
`tests/conformance/patterns.json` checks that the two accept the same strings.
Instruments implement the same list, so nobody writes a regex of their own.
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

/-- The regular expression, in the syntax JSON Schema uses (ECMA-262). -/
def regex : Pat → String
  | hex n => "^[0-9a-f]{" ++ toString n ++ "}$"
  | slug => "^[a-z0-9][a-z0-9-]*$"
  | upperAlnum => "^[A-Z0-9]+$"
  | ownerRepo => "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
  | relPath => "^(?!/)(?!.*(^|/)\\.\\.(/|$))[^\\\\\\x00-\\x1f\\u2028\\u2029]+$"
  | uri => "^[A-Za-z][A-Za-z0-9+.-]*:[^\\x00-\\x20\\x7f]*$"
  | dateTime =>
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"
  | instant =>
    "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
  | decimal => "^(0|-?[1-9][0-9]*)$"

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

private def isDigit (c : Char) : Bool := '0' ≤ c && c ≤ '9'
private def isLowerHex (c : Char) : Bool := isDigit c || ('a' ≤ c && c ≤ 'f')
private def isLower (c : Char) : Bool := 'a' ≤ c && c ≤ 'z'
private def isAsciiLetter (c : Char) : Bool := isLower c || ('A' ≤ c && c ≤ 'Z')
private def isRepoChar (c : Char) : Bool :=
  isAsciiLetter c || isDigit c || c == '_' || c == '.' || c == '-'
private def isControl (c : Char) : Bool := c.toNat < 0x20

private def digits : List Char → Nat → Option (List Char)
  | cs, 0 => some cs
  | c :: cs, n + 1 => if isDigit c then digits cs n else none
  | [], _ + 1 => none

/-- One or more digits, then the rest. -/
private def someDigits : List Char → Option (List Char)
  | c :: cs => if isDigit c then some (cs.dropWhile isDigit) else none
  | [] => none

private def lit (c : Char) : List Char → Option (List Char)
  | d :: ds => if c == d then some ds else none
  | [] => none

private def offsetOk : List Char → Bool
  | ['Z'] => true
  | s :: rest =>
    (s == '+' || s == '-') &&
      ((digits rest 2 >>= lit ':' >>= (digits · 2)) == some [])
  | [] => false

private def dateTimeOk (cs : List Char) : Bool :=
  let head := digits cs 4 >>= lit '-' >>= (digits · 2) >>= lit '-' >>= (digits · 2)
    >>= lit 'T' >>= (digits · 2) >>= lit ':' >>= (digits · 2) >>= lit ':' >>= (digits · 2)
  match head with
  | none => false
  | some rest =>
    match rest with
    | '.' :: frac =>
      match someDigits frac with
      | some r => offsetOk r
      | none => false
    | _ => offsetOk rest

/-- Two digits making a number from 0 to `hi`. -/
private def twoDigits (hi : Nat) : List Char → Option (List Char)
  | a :: b :: rest =>
    if isDigit a && isDigit b && (a.toNat - 48) * 10 + (b.toNat - 48) ≤ hi then some rest else none
  | _ => none

/-- Two digits from 1 to `hi`. -/
private def twoDigitsPos (hi : Nat) : List Char → Option (List Char)
  | a :: b :: rest =>
    let v := (a.toNat - 48) * 10 + (b.toNat - 48)
    if isDigit a && isDigit b && 1 ≤ v && v ≤ hi then some rest else none
  | _ => none

private def instantOk (cs : List Char) : Bool :=
  let head := digits cs 4 >>= lit '-' >>= twoDigitsPos 12 >>= lit '-' >>= twoDigitsPos 31
    >>= lit 'T' >>= twoDigits 23 >>= lit ':' >>= twoDigits 59 >>= lit ':' >>= twoDigits 59
  match head with
  | some ['Z'] => true
  | some (s :: rest) =>
    (s == '+' || s == '-') && ((twoDigits 23 rest >>= lit ':' >>= twoDigits 59) == some [])
  | _ => false

private def decimalOk : List Char → Bool
  | ['0'] => true
  | '-' :: c :: cs => c != '0' && isDigit c && cs.all isDigit
  | c :: cs => c != '0' && isDigit c && cs.all isDigit
  | [] => false

/-- The Lean side of each pattern. It accepts exactly what `regex` accepts. -/
def check : Pat → String → Bool
  | hex n, s => s.length == n && s.all isLowerHex
  | slug, s =>
    match s.toList with
    | c :: _ => (isLower c || isDigit c) && s.all (fun c => isLower c || isDigit c || c == '-')
    | [] => false
  | upperAlnum, s => !s.isEmpty && s.all (fun c => ('A' ≤ c && c ≤ 'Z') || isDigit c)
  | ownerRepo, s =>
    match s.splitOn "/" with
    | [a, b] => !a.isEmpty && !b.isEmpty && a.all isRepoChar && b.all isRepoChar
    | _ => false
  | relPath, s =>
    !s.isEmpty && !s.startsWith "/" &&
      s.all (fun c => c != '\\' && !isControl c && c != ' ' && c != ' ') &&
      !(s.splitOn "/").contains ".."
  | uri, s =>
    match s.toList with
    | c :: cs =>
      let scheme := cs.takeWhile (· != ':')
      let rest := cs.drop scheme.length
      isAsciiLetter c &&
        scheme.all (fun c => isAsciiLetter c || isDigit c || c == '+' || c == '.' || c == '-') &&
        (match rest with
         | ':' :: tail => tail.all (fun c => c.toNat > 0x20 && c.toNat != 0x7f)
         | _ => false)
    | [] => false
  | dateTime, s => dateTimeOk s.toList
  | instant, s => instantOk s.toList
  | decimal, s => decimalOk s.toList

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
