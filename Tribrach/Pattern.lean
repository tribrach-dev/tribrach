import Lean.Data.Json

/-!
# Pattern trees

A string pattern written as data: a small regex syntax tree (`Re`). It is
the source of truth for every string pattern a schema may use. From one tree
Tribrach gets:

* `Re.accepts`: the Lean checker, the one proofs and decoders use;
* `Re.toRegex`: the regular expression for JSON Schema (ECMA-262);
* `Re.toJson`: the tree itself, exported in `tests/conformance/patterns.json`
  so instruments run one generic matcher instead of a checker per pattern,
  and so adapters can render the pattern in their own dialect (a Postgres
  `CHECK`, for example) instead of trusting a regex to mean the same thing.

The tree is deliberately smaller than a regex: literals, character sets,
sequences, choices and bounded or unbounded repeats, plus `without`, which
refuses strings that start with a prefix or contain a separated segment (the
two lookaheads `relPath` needs). There are no backreferences, no general
lookaround and no flags.
-/

open Lean

namespace Tribrach

/-- One member of a character set. -/
inductive Item where
  | char (c : Char)
  | range (lo hi : Char)
  deriving Repr, BEq, Inhabited

/-- What `Re.without` refuses, judged on the rest of the string from where it
stands. -/
inductive Ban where
  /-- The string starts with `s`. -/
  | startsWith (s : String)
  /-- Split on `sep`, some segment equals `seg`. -/
  | segment (sep : Char) (seg : String)
  deriving Repr, BEq, Inhabited

/-- A pattern tree. -/
inductive Re where
  | lit (s : String)
  /-- One character in the set, or with `negated`, one character not in it. -/
  | set (items : List Item) (negated : Bool := false)
  | seq (rs : List Re)
  /-- One of the alternatives. -/
  | alt (rs : List Re)
  /-- `r` repeated from `min` to `max` times (no `max`: unbounded). -/
  | rep (r : Re) (min : Nat) (max : Option Nat)
  /-- `r`, refusing what any ban matches. -/
  | without (r : Re) (bans : List Ban)
  deriving Repr, BEq, Inhabited

namespace Item
def hit (c : Char) : Item → Bool
  | char d => c == d
  | range lo hi => lo ≤ c && c ≤ hi
end Item

namespace Ban
def hits (cs : List Char) : Ban → Bool
  | startsWith s => s.toList.isPrefixOf cs
  | segment sep seg => (cs.splitOn sep).contains seg.toList
end Ban

namespace Re

/-- Common shapes. -/
def digit : Re := set [.range '0' '9']
def exactly (n : Nat) (r : Re) : Re := rep r n (some n)
def opt (r : Re) : Re := rep r 0 (some 1)
def many (r : Re) : Re := rep r 0 none
def many1 (r : Re) : Re := rep r 1 none

/-- Remainders after one more round of `step` from each of `front`, keeping
one copy of each (they are suffixes, so length identifies them). -/
private def dedup (xs : List (List Char)) : List (List Char) :=
  xs.foldl (fun acc x => if acc.any (·.length == x.length) then acc else acc ++ [x]) []

/-- Repeat `step` at least `lo` and at most `hi` times. Rounds that make no
progress are dropped, so unbounded repeats stop after at most `fuel` rounds,
where `fuel` is the input length plus one. -/
private def repeatSteps (step : List Char → List (List Char)) (lo : Nat) (hi : Option Nat) :
    Nat → Nat → List (List Char) → List (List Char)
  | 0, _, _ => []
  | fuel + 1, k, front =>
    let here := if lo ≤ k then front else []
    let more := match hi with
      | some h => decide (k < h)
      | none => true
    if !more || front.isEmpty then here
    else
      let next := dedup (front.flatMap fun cs =>
        (step cs).filter (fun r => r.length < cs.length || k < lo))
      dedup (here ++ repeatSteps step lo hi fuel (k + 1) next)

/-- Every remainder left after matching `r` at the start of `cs`. -/
def steps : Re → List Char → List (List Char)
  | lit s, cs => if s.toList.isPrefixOf cs then [cs.drop s.length] else []
  | set items neg, cs =>
    match cs with
    | c :: rest => if items.any (·.hit c) != neg then [rest] else []
    | [] => []
  | seq rs, cs =>
    rs.attach.foldl (fun front ⟨r, _⟩ => dedup (front.flatMap (steps r))) [cs]
  | alt rs, cs => dedup (rs.attach.flatMap fun ⟨r, _⟩ => steps r cs)
  | rep r lo hi, cs => repeatSteps (steps r) lo hi (cs.length + lo + 1) 0 [cs]
  | without r bans, cs => if bans.any (·.hits cs) then [] else steps r cs

/-- The whole string matches. -/
def accepts (r : Re) (s : String) : Bool := (r.steps s.toList).any (·.isEmpty)

private def hex2 (n : Nat) : String :=
  let d := Nat.toDigits 16 n
  String.ofList (List.replicate (2 - d.length) '0' ++ d)

private def hex4 (n : Nat) : String :=
  let d := Nat.toDigits 16 n
  String.ofList (List.replicate (4 - d.length) '0' ++ d)

/-- A character outside a set. -/
private def escLit (c : Char) : String :=
  if "\\^$.|?*+()[]{}".contains c then "\\" ++ c.toString
  else if c.toNat < 0x20 || c.toNat == 0x7f then "\\x" ++ hex2 c.toNat
  else if c.toNat ≥ 0x80 then "\\u" ++ hex4 c.toNat
  else c.toString

/-- A character inside a set; `-` is plain only as the last member. -/
private def escSet (last : Bool) (c : Char) : String :=
  if c == '\\' || c == ']' || c == '^' then "\\" ++ c.toString
  else if c == '-' then (if last then "-" else "\\-")
  else if c.toNat ≤ 0x20 || c.toNat == 0x7f then "\\x" ++ hex2 c.toNat
  else if c.toNat ≥ 0x80 then "\\u" ++ hex4 c.toNat
  else c.toString

private def items (xs : List Item) : String :=
  let n := xs.length
  String.join <| xs.zipIdx.map fun (it, i) =>
    let last := i + 1 == n
    match it with
    | .char c => escSet last c
    | .range lo hi => escSet false lo ++ "-" ++ escSet false hi

private def quant (lo : Nat) : Option Nat → String
  | none => if lo == 0 then "*" else if lo == 1 then "+" else "{" ++ toString lo ++ ",}"
  | some hi =>
    if lo == 0 && hi == 1 then "?"
    else if lo == hi then "{" ++ toString lo ++ "}"
    else "{" ++ toString lo ++ "," ++ toString hi ++ "}"

private def banRegex : Ban → String
  | .startsWith s => "(?!" ++ String.join (s.toList.map escLit) ++ ")"
  | .segment sep seg =>
    "(?!.*(^|" ++ escLit sep ++ ")" ++ String.join (seg.toList.map escLit) ++ "(" ++ escLit sep ++ "|$))"

/-- The regex body, without anchors. -/
def body : Re → String
  | lit s => String.join (s.toList.map escLit)
  | set xs neg => "[" ++ (if neg then "^" else "") ++ items xs ++ "]"
  | seq rs => String.join (rs.attach.map fun ⟨r, _⟩ => body r)
  | alt rs => "(" ++ "|".intercalate (rs.attach.map fun ⟨r, _⟩ => body r) ++ ")"
  | rep r lo hi =>
    let b := body r
    let bare := match r with
      | set .. | alt .. => true
      | lit s => s.length == 1
      | _ => false
    (if bare then b else "(" ++ b ++ ")") ++ quant lo hi
  | without r bans => String.join (bans.map banRegex) ++ body r

/-- The anchored regular expression, as JSON Schema's `pattern` (ECMA-262). -/
def toRegex (r : Re) : String := "^" ++ body r ++ "$"

private def itemJson : Item → Json
  | .char c => Json.str c.toString
  | .range lo hi => Json.arr #[Json.str lo.toString, Json.str hi.toString]

private def banJson : Ban → Json
  | .startsWith s => Json.mkObj [("startsWith", Json.str s)]
  | .segment sep seg => Json.mkObj [("segment", Json.str seg), ("sep", Json.str sep.toString)]

/-- The tree as JSON, for instruments and adapters:
`{"lit": s}`, `{"set": items}` or `{"notSet": items}` (an item is a
one-character string or a `[lo, hi]` pair), `{"seq": [..]}`, `{"alt": [..]}`,
`{"rep": r, "min": n, "max": n | null}`, `{"without": r, "bans": [..]}` with
bans `{"startsWith": s}` and `{"segment": s, "sep": c}`. -/
def toJson : Re → Json
  | lit s => Json.mkObj [("lit", Json.str s)]
  | set xs neg => Json.mkObj [(if neg then "notSet" else "set", Json.arr (xs.map itemJson).toArray)]
  | seq rs => Json.mkObj [("seq", Json.arr (rs.attach.map fun ⟨r, _⟩ => toJson r).toArray)]
  | alt rs => Json.mkObj [("alt", Json.arr (rs.attach.map fun ⟨r, _⟩ => toJson r).toArray)]
  | rep r lo hi => Json.mkObj [("rep", toJson r), ("min", Json.num lo),
      ("max", match hi with | some h => Json.num h | none => Json.null)]
  | without r bans => Json.mkObj [("without", toJson r), ("bans", Json.arr (bans.map banJson).toArray)]

end Re
end Tribrach
