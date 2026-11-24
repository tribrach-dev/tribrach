/-!
# Models

A `Model` is the ground truth that every instrument measures against: a state
type, the rules (invariant) that state must always satisfy, and the operations
that change it. Host code (Go, Swift, a database schema) is linked to a model;
it is never trusted on its own.
-/

namespace Tribrach

/-- A system model: states, the invariant they must keep, and operations. -/
structure Model where
  /-- The state of the system. -/
  State : Type
  /-- The rules every reachable state must satisfy. -/
  Inv : State → Prop
  /-- The operations a user or service can perform. -/
  Op : Type
  /-- What each operation does to the state. -/
  step : Op → State → State

namespace Model

/-- Every operation keeps the rules. This is the property a model proves once,
so that instruments only need to check that host code matches the model. -/
def Preserves (m : Model) : Prop :=
  ∀ (o : m.Op) (s : m.State), m.Inv s → m.Inv (m.step o s)

/-- Run a sequence of operations from a starting state. Instruments replay the
same sequences against host code and compare the results. -/
def run (m : Model) (ops : List m.Op) (s : m.State) : m.State :=
  ops.foldl (fun acc o => m.step o acc) s

/-- If every operation keeps the rules, so does any sequence of operations. -/
theorem run_preserves (m : Model) (h : m.Preserves) :
    ∀ (ops : List m.Op) (s : m.State), m.Inv s → m.Inv (m.run ops s) := by
  intro ops
  induction ops with
  | nil =>
    intro s hs
    exact hs
  | cons o os ih =>
    intro s hs
    exact ih (m.step o s) (h o s hs)

end Model
end Tribrach
