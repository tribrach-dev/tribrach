import Lean.Data.Json
import Tribrach.Logic

/-!
# Shared pieces for the benchmark models

Each model is a small decision function written as Datalog rules. Its
`encode` step turns one JSON input into given facts (this is where numeric
thresholds live); the rules then decide. The decisions (`outcomes`) are the
facts whose predicate is listed in `decisions`.
-/

namespace Bench

open Tribrach.Logic
open Lean (Json)

def c (s : String) : Term := .const s
def v (s : String) : Term := .var s
def fact (p : String) (args : List String := []) : Fact := { pred := p, args }
def atom (p : String) (args : List Term := []) : Atom := { pred := p, args }

structure BenchModel where
  name : String
  encode : Json → Except String (List Fact)
  rules : List Rule
  templates : Templates
  decisions : List String

def BenchModel.run (m : BenchModel) (input : Json) : Except String (List Fact × Result) := do
  let facts ← m.encode input
  return (facts, saturate facts m.rules)

/-- The decisions for one input, as sorted strings such as `water lawn`. -/
def BenchModel.outcomes (m : BenchModel) (res : Result) : List (String × Why) :=
  let ds := res.db.filter (fun p => m.decisions.contains p.1.pred)
  let named := ds.map (fun p => (" ".intercalate (p.1.pred :: p.1.args), p.2))
  named.toArray.qsort (fun a b => a.1 < b.1) |>.toList

def getInt (j : Json) (k : String) : Except String Int := j.getObjValAs? Int k
def getStr (j : Json) (k : String) : Except String String := j.getObjValAs? String k
def getBool (j : Json) (k : String) : Except String Bool := j.getObjValAs? Bool k
def getArr (j : Json) (k : String) : Except String (Array Json) := do
  (← j.getObjVal? k).getArr?

def when (b : Bool) (f : Fact) : List Fact := if b then [f] else []

end Bench
