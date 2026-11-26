import Lean
import Tribrach.Model
import Tribrach.Link

/-!
# Exporters: stamps, manifests and vectors

Instruments never read Lean. They read three files that a project's Lean
exporter writes:

* a **manifest** (`tribrach.manifest.v1`): one entry per link, naming the Lean
  definition, the instrument that owns the link, the host symbol and the
  definition's stamp;
* **vectors** (`tribrach.vectors.v1`): operation sequences with the state the
  model reaches after every step, for replay against host code;
* **stamps**, carried inside both: a hash of a Lean definition and of
  everything it uses from the same Lean file.

## Stamps

`stamp% Counter.counterStep` elaborates to the definition's stamp as a string
literal of 16 hex digits. The hash covers the definition's type and value,
and, transitively, every constant they use that comes from the same module
(auxiliary `match` definitions, the operation type and its constructors,
helper functions). Constants from other modules are referred to by name only.

A stamp is stable for a given Lean toolchain. A toolchain bump may change
every stamp; instruments then report drift and the project refreshes the
recorded stamps, which is the intended behaviour: the stamp says "look
again", not "this is wrong".

## Writing an exporter

```lean
def manifest : Export.Manifest :=
  { package := "counter",
    links := [Export.link (lean% Counter.counterStep) .go "example.com/counter.Step"] }

def main : IO Unit := do
  IO.FS.writeFile "counter.manifest.json" manifest.render
  IO.FS.writeFile "counter.vectors.json" (Export.vectors codec cases).render
```
-/

open Lean

namespace Tribrach
namespace Export

/-- A 64-bit value as 16 lowercase hex digits. -/
def hex64 (h : UInt64) : String :=
  let s := String.ofList (Nat.toDigits 16 h.toNat)
  "".pushn '0' (16 - s.length) ++ s

/-- Whether a string is a well-formed stamp: 16 lowercase hex digits. -/
def isStamp (s : String) : Bool :=
  s.length == 16 && s.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

/-- The stamp of a constant: its type and value, plus those of every constant
they use from the same module, followed transitively. -/
def stampOf (root : Name) : CoreM String := do
  let env ← getEnv
  let home := env.getModuleIdxFor? root
  let mut todo : Array Name := #[root]
  let mut seen : NameSet := {}
  let mut acc : UInt64 := 1469598103934665603
  let mut i := 0
  while i < todo.size do
    let n := todo[i]!
    i := i + 1
    if seen.contains n then continue
    seen := seen.insert n
    let some ci := env.find? n
      | throwError "stamp%: unknown constant {n}"
    acc := mixHash acc (hash n)
    acc := mixHash acc ci.type.hash
    let mut uses : Array Name := ci.type.getUsedConstants
    if let some v := ci.value? then
      acc := mixHash acc v.hash
      uses := uses ++ v.getUsedConstants
    if let .inductInfo iv := ci then
      uses := uses ++ iv.ctors.toArray
    for c in uses do
      if !seen.contains c && env.getModuleIdxFor? c == home then
        todo := todo.push c
  return hex64 acc

/-- A Lean definition as a manifest refers to it: its full name and stamp. -/
structure LeanRef where
  name : String
  stamp : String
  deriving Repr, Inhabited

/-- `stamp% Foo.bar` is the stamp of `Foo.bar`, as a string literal. -/
elab "stamp% " id:ident : term => do
  let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
  return mkStrLit (← stampOf n)

/-- `lean% Foo.bar` is a `LeanRef` for `Foo.bar`: its name and stamp. -/
elab "lean% " id:ident : term => do
  let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
  let s ← stampOf n
  return mkAppN (mkConst ``LeanRef.mk) #[mkStrLit n.toString, mkStrLit s]

/-- A manifest link from a Lean reference. -/
def link (r : LeanRef) (owner : InstrumentId) (symbol : String) : Link :=
  { leanName := r.name, owner, symbol, stamp := r.stamp }

def linkJson (l : Link) : Json :=
  Json.mkObj [("lean", Json.str l.leanName), ("owner", Json.str (toString l.owner)),
              ("symbol", Json.str l.symbol), ("stamp", Json.str l.stamp)]

/-- `tribrach.manifest.v1`: the links of one package. -/
structure Manifest where
  /-- The project or package the links belong to. -/
  package : String
  links : List Link

def Manifest.toJson (m : Manifest) : Json :=
  Json.mkObj [("format", Json.str "tribrach.manifest.v1"), ("package", Json.str m.package),
              ("links", Json.arr (m.links.map linkJson).toArray)]

def Manifest.render (m : Manifest) : String := m.toJson.pretty ++ "\n"

/-- How a model's states and operations are written for host code. By
convention an operation is an object whose `op` field names it, with its
arguments as further fields: `{"op": "add", "title": "milk"}`. -/
structure Codec (m : Model) where
  /-- The model id vectors and reports name, such as `counter.v1`. -/
  model : String
  encodeState : m.State → Json
  encodeOp : m.Op → Json

/-- One replay case: a start state and the operations to perform. -/
structure Case (m : Model) where
  id : String
  start : m.State
  ops : List m.Op

/-- The state after each operation, in order. -/
def _root_.Tribrach.Model.trace (m : Model) : List m.Op → m.State → List m.State
  | [], _ => []
  | o :: os, s => m.step o s :: m.trace os (m.step o s)

/-- There is one expected state per operation. -/
theorem _root_.Tribrach.Model.trace_length (m : Model) :
    ∀ (ops : List m.Op) (s : m.State), (m.trace ops s).length = ops.length
  | [], _ => rfl
  | _ :: os, s => by
    simp only [Model.trace, List.length_cons, Model.trace_length m os]

/-- When the model keeps its rules, every expected state in a vector keeps
them too, so a host that matches the vectors never needs a state the model
would reject. -/
theorem _root_.Tribrach.Model.trace_preserves (m : Model) (h : m.Preserves) :
    ∀ (ops : List m.Op) (s : m.State), m.Inv s → ∀ x ∈ m.trace ops s, m.Inv x
  | [], _, _, x, hx => by simp [Model.trace] at hx
  | o :: os, s, hs, x, hx => by
    simp only [Model.trace, List.mem_cons] at hx
    rcases hx with rfl | hx
    · exact h o s hs
    · exact Model.trace_preserves m h os (m.step o s) (h o s hs) x hx

def Case.toJson {m : Model} (c : Codec m) (k : Case m) : Json :=
  Json.mkObj [("id", Json.str k.id), ("start", c.encodeState k.start),
              ("ops", Json.arr (k.ops.map c.encodeOp).toArray),
              ("states", Json.arr ((m.trace k.ops k.start).map c.encodeState).toArray)]

/-- `tribrach.vectors.v1`: replay cases for one model. -/
structure Vectors (m : Model) where
  codec : Codec m
  cases : List (Case m)

def vectors {m : Model} (codec : Codec m) (cases : List (Case m)) : Vectors m :=
  { codec, cases }

def Vectors.toJson {m : Model} (v : Vectors m) : Json :=
  Json.mkObj [("format", Json.str "tribrach.vectors.v1"), ("model", Json.str v.codec.model),
              ("cases", Json.arr (v.cases.map (Case.toJson v.codec)).toArray)]

def Vectors.render {m : Model} (v : Vectors m) : String := v.toJson.pretty ++ "\n"

end Export
end Tribrach
