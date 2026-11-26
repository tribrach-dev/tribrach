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
  deriving Repr, BEq, Inhabited

namespace Pat

/-- The regular expression, in the syntax JSON Schema uses (ECMA-262). -/
def regex : Pat → String
  | hex n => "^[0-9a-f]{" ++ toString n ++ "}$"
  | slug => "^[a-z0-9][a-z0-9-]*$"
  | ownerRepo => "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
  | relPath => "^(?!/)(?!.*(^|/)\\.\\.(/|$))[^\\\\\\x00-\\x1f\\u2028\\u2029]+$"
  | uri => "^[A-Za-z][A-Za-z0-9+.-]*:[^\\x00-\\x20\\x7f]*$"
  | dateTime =>
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"

/-- A JSON Schema `format` to add beside the pattern, for tools that use it. -/
def format? : Pat → Option String
  | uri => some "uri"
  | dateTime => some "date-time"
  | _ => none

/-- The name conformance cases use. -/
def name : Pat → String
  | hex n => "hex" ++ toString n
  | slug => "slug"
  | ownerRepo => "ownerRepo"
  | relPath => "relPath"
  | uri => "uri"
  | dateTime => "dateTime"

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

/-- The Lean side of each pattern. It accepts exactly what `regex` accepts. -/
def check : Pat → String → Bool
  | hex n, s => s.length == n && s.all isLowerHex
  | slug, s =>
    match s.toList with
    | c :: _ => (isLower c || isDigit c) && s.all (fun c => isLower c || isDigit c || c == '-')
    | [] => false
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

/-- Every pattern conformance covers. -/
def all : List Pat := [hex 16, hex 40, hex 64, slug, ownerRepo, relPath, uri, dateTime]

end Pat

/-- The shape of a JSON value. Objects are closed: a key the type doesn't
name is an error. -/
inductive Ty where
  | bool
  /-- A whole number; JSON numbers like `2.0` count. -/
  | int (min : Option Int := none) (max : Option Int := none)
  /-- A string; lengths count Unicode code points. -/
  | str (minLen : Option Nat := none) (maxLen : Option Nat := none) (pat : Option Pat := none)
  | constInt (n : Int)
  | constStr (s : String)
  /-- One of these strings. -/
  | enum (values : List String)
  | arr (item : Ty) (minItems : Option Nat := none) (maxItems : Option Nat := none)
  /-- Fields as (name, type, required). -/
  | obj (fields : List (String × Ty × Bool))
  /-- A description for people; it doesn't change what is accepted. -/
  | doc (text : String) (ty : Ty)
  deriving Inhabited

/-- A required field. -/
def req (name : String) (ty : Ty) : String × Ty × Bool := (name, ty, true)
/-- An optional field. -/
def opt (name : String) (ty : Ty) : String × Ty × Bool := (name, ty, false)

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
  | .int lo hi => Json.mkObj ([("type", Json.str "integer")] ++ optField "minimum" (lo.map Lean.toJson)
      ++ optField "maximum" (hi.map Lean.toJson))
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
  | .doc d t => t.toJson.setObjVal! "description" (Json.str d)

def Ty.fieldsJson : List (String × Ty × Bool) → List (String × Json)
  | [] => []
  | (n, t, _) :: rest => (n, t.toJson) :: Ty.fieldsJson rest
end

mutual
/-- Whether a JSON value has this type. -/
def Ty.check : Ty → Json → Bool
  | .bool, .bool _ => true
  | .int lo hi, .num n =>
    match asInt? n with
    | some i => lo.all (· ≤ i) && hi.all (i ≤ ·)
    | none => false
  | .str lo hi p, .str s =>
    lo.all (· ≤ s.length) && hi.all (s.length ≤ ·) && p.all (·.check s)
  | .constInt n, .num m => asInt? m == some n
  | .constStr s, .str t => s == t
  | .enum vs, .str s => vs.contains s
  | .arr t lo hi, .arr xs =>
    lo.all (· ≤ xs.size) && hi.all (xs.size ≤ ·) && Ty.checkItems t xs.toList
  | .obj fs, .obj kvs =>
    kvs.all (fun k _ => fs.any (·.1 == k)) && Ty.checkFields fs (.obj kvs)
  | .doc _ t, j => t.check j
  | _, _ => false

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
   "minLength", "maxLength", "pattern", "format", "minItems", "maxItems", "items",
   "additionalProperties", "required", "properties", "x-tribrach", "rules", "lean", "stamp", "doc"]

private def entries (kvs : Std.TreeMap.Raw String Json compare) : Array (String × Json) :=
  let rank (k : String) := (keyOrder.idxOf? k).getD keyOrder.length
  (kvs.foldl (fun acc k v => acc.push (k, v)) #[]).qsort fun a b =>
    rank a.1 < rank b.1 || (rank a.1 == rank b.1 && a.1 < b.1)

/-- One line, keys in `keyOrder`. -/
partial def oneLine : Json → String
  | .arr xs => "[" ++ ", ".intercalate (xs.toList.map oneLine) ++ "]"
  | .obj kvs =>
    let es := entries kvs
    if es.isEmpty then "{}"
    else "{ " ++ ", ".intercalate (es.toList.map fun (k, v) =>
      (Json.str k).compress ++ ": " ++ oneLine v) ++ " }"
  | j => j.compress

/-- Two-space indented JSON, keys in `keyOrder`, short values on one line. -/
partial def renderJson (j : Json) (indent : String := "") : String :=
  let flat := oneLine j
  if indent.length + flat.length ≤ 96 then flat else
  let inner := indent ++ "  "
  match j with
  | .arr xs => "[\n" ++ ",\n".intercalate (xs.toList.map fun x => inner ++ renderJson x inner)
      ++ "\n" ++ indent ++ "]"
  | .obj kvs => "{\n" ++ ",\n".intercalate ((entries kvs).toList.map fun (k, v) =>
      inner ++ (Json.str k).compress ++ ": " ++ renderJson v inner) ++ "\n" ++ indent ++ "}"
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
end Checks

end Schema
end Tribrach
