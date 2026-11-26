import Tribrach.Relation

/-!
# Shipments: several valid outcomes

An order for some units can be shipped in parts. Asking the warehouse to ship
`n` units may legitimately end in several ways:

- it ships any number from 1 to `n` (a partial shipment is fine),
- it fails because the stock isn't there (nothing changes),
- or, if the request makes no sense (the order is cancelled, `n` is zero, or
  more than what's left), it is refused.

The rule is that the order never ships more than was ordered.
-/

namespace Shipments

structure Order where
  ordered : Nat
  shipped : Nat
  cancelled : Bool
  deriving DecidableEq, Repr

inductive Op where
  | ship (n : Nat)
  | cancel
  deriving Repr

inductive Err where
  | outOfStock
  deriving DecidableEq, Repr

abbrev Out := Tribrach.Outcome Order Err

/-- Which outcomes of shipping `n` units are allowed. -/
def shipAllowed (s : Order) (n : Nat) : Out → Bool
  | .done s' => decide (s.cancelled = false ∧ 0 < n ∧ n ≤ s.ordered - s.shipped ∧
      s'.ordered = s.ordered ∧ s'.cancelled = false ∧
      s.shipped < s'.shipped ∧ s'.shipped ≤ s.shipped + n)
  | .refused => decide (s.cancelled = true ∨ n = 0 ∨ s.ordered - s.shipped < n)
  | .failed .outOfStock => decide (s.cancelled = false ∧ 0 < n ∧ n ≤ s.ordered - s.shipped)

/-- Which outcomes of cancelling are allowed: an order that isn't fully
shipped can be cancelled; otherwise cancelling is refused. It never fails. -/
def cancelAllowed (s : Order) : Out → Bool
  | .done s' => decide (s.cancelled = false ∧ s.shipped < s.ordered ∧ s' = { s with cancelled := true })
  | .refused => decide (s.cancelled = true ∨ s.ordered ≤ s.shipped)
  | .failed _ => false

def allowedB : Op → Order → Out → Bool
  | .ship n, s, out => shipAllowed s n out
  | .cancel, s, out => cancelAllowed s out

def shipments : Tribrach.RelModel where
  State := Order
  Inv := fun s => s.shipped ≤ s.ordered
  Op := Op
  Err := Err
  allowed := fun o s out => allowedB o s out = true

theorem ship_done_le (s s' : Order) (n : Nat) (hs : s.shipped ≤ s.ordered)
    (h : shipAllowed s n (.done s') = true) : s'.shipped ≤ s'.ordered := by
  have h' := of_decide_eq_true h
  obtain ⟨_, _, hn, hord, _, _, hle⟩ := h'
  omega

theorem cancel_done_le (s s' : Order) (hs : s.shipped ≤ s.ordered)
    (h : cancelAllowed s (.done s') = true) : s'.shipped ≤ s'.ordered := by
  have h' := of_decide_eq_true h
  obtain ⟨_, _, rfl⟩ := h'
  exact hs

/-- Every allowed outcome keeps the rule, whichever one the warehouse picks. -/
theorem shipments_preserves : shipments.Preserves := by
  intro o s out hs h
  cases o with
  | ship n =>
    cases out with
    | done s' => exact ship_done_le s s' n hs h
    | refused => exact hs
    | failed e => exact hs
  | cancel =>
    cases out with
    | done s' => exact cancel_done_le s s' hs h
    | refused => exact hs
    | failed e => exact hs

/-- So does every allowed trace. -/
theorem shipments_trace {s t : Order} {steps}
    (ht : shipments.Trace s steps t) (hs : s.shipped ≤ s.ordered) : t.shipped ≤ t.ordered :=
  Tribrach.RelModel.trace_preserves shipments shipments_preserves ht hs

/-- Progress: every request has some allowed outcome (a refusal at worst). -/
theorem shipments_total : shipments.Total := by
  intro o s _
  cases o with
  | ship n =>
    by_cases hr : s.cancelled = true ∨ n = 0 ∨ s.ordered - s.shipped < n
    · refine ⟨.refused, ?_⟩
      show shipAllowed s n .refused = true
      simp only [shipAllowed, decide_eq_true_eq]
      exact hr
    · simp only [not_or] at hr
      obtain ⟨h1, h2, h3⟩ := hr
      refine ⟨.failed .outOfStock, ?_⟩
      show shipAllowed s n (.failed .outOfStock) = true
      simp only [shipAllowed, decide_eq_true_eq]
      exact ⟨by simpa using h1, by omega, by omega⟩
  | cancel =>
    by_cases hr : s.cancelled = true ∨ s.ordered ≤ s.shipped
    · refine ⟨.refused, ?_⟩
      show cancelAllowed s .refused = true
      simp only [cancelAllowed, decide_eq_true_eq]
      exact hr
    · simp only [not_or] at hr
      obtain ⟨h1, h2⟩ := hr
      refine ⟨.done { s with cancelled := true }, ?_⟩
      show cancelAllowed s (.done { s with cancelled := true }) = true
      simp only [cancelAllowed, decide_eq_true_eq]
      exact ⟨by simpa using h1, by omega, by simp⟩

end Shipments
