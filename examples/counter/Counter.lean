import Tribrach.Model
import Tribrach.Relation

/-!
# Example: a bounded counter

The smallest useful model: a counter that never goes above `max`.
-/

namespace Counter

/-- What a user can do to the counter. -/
inductive CounterOp where
  | incr
  | reset
  deriving Repr, DecidableEq

/-- The pure core. Host code links to this and must match it on every
replayed sequence. -/
def counterStep (max : Nat) : CounterOp → Nat → Nat
  | .incr, n => if n < max then n + 1 else n
  | .reset, _ => 0

/-- Each operation keeps the counter at or below `max`. -/
theorem counterStep_le (max : Nat) (o : CounterOp) (n : Nat) (h : n ≤ max) :
    counterStep max o n ≤ max := by
  cases o with
  | incr =>
    show (if n < max then n + 1 else n) ≤ max
    split <;> omega
  | reset => exact Nat.zero_le max

/-- The counter as a Tribrach model. -/
def counter (max : Nat) : Tribrach.Model where
  State := Nat
  Inv := fun n => n ≤ max
  Op := CounterOp
  step := counterStep max

theorem counter_preserves (max : Nat) : (counter max).Preserves := by
  intro o n h
  exact counterStep_le max o n h

/-- Any sequence of operations keeps the rule, for free. -/
theorem counter_run_le (max : Nat) (ops : List CounterOp) :
    (counter max).Inv ((counter max).run ops (0 : Nat)) :=
  Tribrach.Model.run_preserves (counter max) (counter_preserves max) ops (0 : Nat)
    (Nat.zero_le max)

/-- The same counter through the relational API, via the adapter. -/
theorem counter_rel_preserves (max : Nat) : (counter max).toRel.Preserves :=
  Tribrach.Model.toRel_preserves (counter max) (counter_preserves max)

end Counter
