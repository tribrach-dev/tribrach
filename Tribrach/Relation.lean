import Tribrach.Model

/-!
# Relational transition contracts

`Model.step` gives exactly one next state per operation. Some contracts need
more room: an operation can be refused, it can fail, or several outcomes can
all be acceptable (a warehouse may ship part of an order or all of it). A
`RelModel` says which outcomes are *allowed*, instead of computing the one
outcome.

## Outcomes

- `done s'`: the operation ran and the state is now `s'`. An accepted
  operation that changes nothing is `done s` with the same state.
- `refused`: the operation is not enabled in this state (for example,
  shipping a cancelled order). The state is unchanged by definition.
- `failed e`: the operation was attempted and failed with error `e` (for
  example, out of stock). The state is unchanged by definition; a failure
  that changes state should be modelled as `done` with the error recorded in
  the state.

## What is and isn't promised

- `Preserves`: every allowed outcome keeps the invariant. With it,
  `trace_preserves` proves every allowed trace keeps it.
- `Total` (progress) is a separate assumption: every operation has at least
  one allowed outcome in every valid state, possibly a refusal. Nothing here
  promises termination; traces are finite lists.
- A replay vector records one observed outcome. Passing it shows that this
  outcome was allowed. It does not show that the implementation never picks
  a forbidden outcome elsewhere, or that it can produce every allowed one.
-/

namespace Tribrach

/-- What happened when an operation was attempted. -/
inductive Outcome (σ ε : Type) where
  | done (s : σ)
  | refused
  | failed (e : ε)
  deriving Repr

/-- The state after an outcome: refusals and failures leave it unchanged. -/
def Outcome.after {σ ε : Type} (out : Outcome σ ε) (s : σ) : σ :=
  match out with
  | .done s' => s'
  | .refused => s
  | .failed _ => s

/-- A model whose operations may have several allowed outcomes. -/
structure RelModel where
  State : Type
  Inv : State → Prop
  Op : Type
  /-- Error kinds an operation can fail with. -/
  Err : Type
  /-- Which outcomes of an operation are allowed in a state. -/
  allowed : Op → State → Outcome State Err → Prop

namespace RelModel

/-- Every allowed outcome keeps the invariant. -/
def Preserves (m : RelModel) : Prop :=
  ∀ (o : m.Op) (s : m.State) (out : Outcome m.State m.Err),
    m.Inv s → m.allowed o s out → m.Inv (out.after s)

/-- Progress, stated separately: in every valid state, every operation has
some allowed outcome (possibly a refusal). -/
def Total (m : RelModel) : Prop :=
  ∀ (o : m.Op) (s : m.State), m.Inv s → ∃ out, m.allowed o s out

/-- A trace from `s` to `t`: each step's outcome was allowed. -/
inductive Trace (m : RelModel) : m.State → List (m.Op × Outcome m.State m.Err) → m.State → Prop
  | nil (s : m.State) : Trace m s [] s
  | cons {s t : m.State} {o : m.Op} {out : Outcome m.State m.Err}
      {rest : List (m.Op × Outcome m.State m.Err)} :
      m.allowed o s out → Trace m (out.after s) rest t → Trace m s ((o, out) :: rest) t

/-- Every allowed trace keeps the invariant. -/
theorem trace_preserves (m : RelModel) (h : m.Preserves)
    {s t : m.State} {steps : List (m.Op × Outcome m.State m.Err)}
    (ht : Trace m s steps t) : m.Inv s → m.Inv t := by
  induction ht with
  | nil _ => exact id
  | cons hstep _ ih => exact fun hs => ih (h _ _ _ hs hstep)

/-- One observed transition, as a replay vector records it. -/
structure Observation (m : RelModel) where
  before : m.State
  op : m.Op
  observed : Outcome m.State m.Err

/-- An observation passes when its outcome is allowed. This is all a
single replay vector can establish. -/
def Observation.Passes {m : RelModel} (v : Observation m) : Prop :=
  m.allowed v.op v.before v.observed

end RelModel

/-- Every deterministic model is a relational one: the only allowed outcome
is `done (step o s)`. It never refuses or fails. -/
def Model.toRel (m : Model) : RelModel where
  State := m.State
  Inv := m.Inv
  Op := m.Op
  Err := Empty
  allowed := fun o s out => out = .done (m.step o s)

theorem Model.toRel_preserves (m : Model) (h : m.Preserves) : m.toRel.Preserves := by
  intro o s out hs hallowed
  have hout : out = .done (m.step o s) := hallowed
  subst hout
  exact h o s hs

theorem Model.toRel_total (m : Model) : m.toRel.Total :=
  fun o s _ => ⟨.done (m.step o s), rfl⟩

end Tribrach
