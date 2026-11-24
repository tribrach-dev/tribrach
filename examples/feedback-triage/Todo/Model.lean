import Lean

/-!
# A to-do model for feedback triage

A tiny to-do list: add an item, complete it, remove it. The rule is that item
ids are unique. A user's report carries the operations they performed and the
state the app ended in; replaying those operations here tells us whether the
app broke the model (a code bug) or followed it (a spec question).
-/

open Lean

namespace Todo

/-- One to-do item. -/
structure Item where
  id : Nat
  done : Bool
  deriving Repr, BEq, FromJson, ToJson

/-- What a user can do. -/
inductive Op where
  | add (id : Nat)
  | complete (id : Nat)
  | remove (id : Nat)
  deriving Repr

/-- The pure core. Adding an id that already exists does nothing. -/
def step : Op → List Item → List Item
  | .add i, s => if s.any (fun it => it.id == i) then s else s ++ [⟨i, false⟩]
  | .complete i, s => s.map (fun it => if it.id == i then { it with done := true } else it)
  | .remove i, s => s.filter (fun it => it.id != i)

/-- Replay a sequence of operations. -/
def run (s : List Item) (ops : List Op) : List Item :=
  ops.foldl (fun acc o => step o acc) s

/-- The rule: every item id appears once. Checked here, not proved; see the
counter example for proofs. -/
def uniqueIds (s : List Item) : Bool :=
  (s.map (·.id)).eraseDups.length == s.length

end Todo
