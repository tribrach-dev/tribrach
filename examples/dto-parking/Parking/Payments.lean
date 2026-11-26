/-!
# The payments service: `payments.authorize`

Payments authorizes a charge in minor units (cents). Whether the card says
yes is outside the model, so `authorize` takes the card network's answer as
an argument; everything else is decided here.
-/

namespace Parking.Payments

/-- The largest charge payments accepts, in minor units. -/
def maxAmount : Nat := 20000

def currencies : List String := ["CAD", "USD"]

structure AuthorizeRequest where
  amount : Nat
  currency : String
  token : String
  deriving BEq, Repr, Inhabited

inductive AuthorizeResponse where
  | authorized (authId : String) (amount : Nat)
  | declined (reason : String)
  deriving BEq, Repr, Inhabited

/-- What payments answers, given the card network's `approve` and the id it
would give the authorization. -/
def authorize (approve : Bool) (authId : String) (r : AuthorizeRequest) : AuthorizeResponse :=
  if 1 ≤ r.amount ∧ r.amount ≤ maxAmount ∧ currencies.contains r.currency then
    if approve then .authorized authId r.amount else .declined "card declined"
  else .declined "amount or currency not accepted"

/-- An authorization is always for exactly the amount asked. -/
theorem authorize_exact {approve id r i a} (h : authorize approve id r = .authorized i a) :
    a = r.amount := by
  unfold authorize at h
  split at h
  · split at h
    · cases h; rfl
    · cases h
  · cases h

/-- An authorization never exceeds the limit. -/
theorem authorize_bounded {approve id r i a} (h : authorize approve id r = .authorized i a) :
    a ≤ maxAmount := by
  have := authorize_exact h
  unfold authorize at h
  split at h
  · rename_i hr; omega
  · cases h

/-- A charge within the limit, in a known currency, that the card approves
is authorized. -/
theorem authorize_accepts {id r} (h1 : 1 ≤ r.amount) (h2 : r.amount ≤ maxAmount)
    (hc : currencies.contains r.currency) : authorize true id r = .authorized id r.amount := by
  have hm : r.currency ∈ currencies := by simpa using hc
  simp [authorize, h1, h2, hm]

end Parking.Payments
