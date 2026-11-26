import Tribrach.Impact

open Tribrach

def cid (s : String) : ContractId := ⟨s⟩

/-! ## The proved side: two revisions of the inventory contract -/

namespace Inventory

structure Stock where
  onHand : Nat
  reserved : Nat

inductive Op where
  | receive (n : Nat)
  | reserve (n : Nat)

def stepV2 : Op → Stock → Stock
  | .receive n, s => { s with onHand := s.onHand + n }
  | .reserve n, s => if s.reserved + n ≤ s.onHand then { s with reserved := s.reserved + n } else s

/-- Revision 2: reservations never exceed stock on hand. -/
def v2 : Model := { State := Stock, Inv := fun s => s.reserved ≤ s.onHand, Op := Op, step := stepV2 }

/-- Shelf space. -/
def cap : Nat := 1000

def stepV3 : Op → Stock → Stock
  | .receive n, s => if s.onHand + n ≤ cap then { s with onHand := s.onHand + n } else s
  | .reserve n, s => stepV2 (.reserve n) s

/-- Revision 3 also caps stock at the shelf space: fewer behaviours, every
old guarantee kept. -/
def v3 : Model :=
  { State := Stock, Inv := fun s => s.reserved ≤ s.onHand ∧ s.onHand ≤ cap, Op := Op, step := stepV3 }

theorem stepV3_inv (o : Op) (s : Stock) (h : s.reserved ≤ s.onHand ∧ s.onHand ≤ cap) :
    (stepV3 o s).reserved ≤ (stepV3 o s).onHand ∧ (stepV3 o s).onHand ≤ cap := by
  cases o with
  | receive n =>
    simp only [stepV3]
    split
    next hc =>
      show s.reserved ≤ s.onHand + n ∧ s.onHand + n ≤ cap
      exact ⟨by omega, by omega⟩
    next => exact h
  | reserve n =>
    simp only [stepV3, stepV2]
    split
    next hc =>
      show s.reserved + n ≤ s.onHand ∧ s.onHand ≤ cap
      exact ⟨by omega, by omega⟩
    next => exact h

theorem v3_preserves : v3.Preserves := fun o s h => stepV3_inv o s h

def v3_strengthens_v2 : Model.Strengthens v3 v2 where
  view := id
  inv := fun _ h => And.left h

/-- What `shipping.orders` uses from revision 2: a reservation can be picked. -/
def canPick (s : Stock) : Prop := s.reserved ≤ s.onHand

/-- The corollary that clears revision 3 for `shipping.orders`. -/
theorem orders_keep_stock_guarantee :
    ∀ (ops : List v3.Op) (s : v3.State), v3.Inv s → canPick (v3_strengthens_v2.view (v3.run ops s)) :=
  Model.carry_over (P := canPick) v3_strengthens_v2 v3_preserves (fun _ h => h)

end Inventory

/-! ## The contract graph -/

/-- Shipping (with its inventory) and billing (with tax). -/
def graph : Graph where
  contracts := [
    { id := cid "inventory.stock", leanName := "Inventory.stock", revision := 4, stamp := "a41f" },
    -- Renamed from `Shipping.OrderBook`; its id, and every reference to it, stayed the same.
    { id := cid "shipping.orders", leanName := "Shipping.Orders", revision := 2, stamp := "77c0" },
    { id := cid "shipping.partial", leanName := "Shipping.partialShipments", revision := 1, stamp := "19be" },
    { id := cid "billing.invoices", leanName := "Billing.invoices", revision := 1, stamp := "c3d2" },
    { id := cid "billing.tax", leanName := "Billing.tax", revision := 2, stamp := "5e11" } ]
  edges := [
    { src := cid "shipping.orders", kind := .dependsOn, dst := cid "inventory.stock", revision := 2 },
    { src := cid "shipping.partial", kind := .refines, dst := cid "shipping.orders", revision := 2 },
    { src := cid "billing.invoices", kind := .dependsOn, dst := cid "shipping.orders", revision := 1 },
    { src := cid "billing.invoices", kind := .dependsOn, dst := cid "billing.tax", revision := 1 } ]
  history := [
    { id := cid "inventory.stock", revision := 3, kind := some .refine,
      compat := .checked "theorem Inventory.orders_keep_stock_guarantee" },
    -- revision 4 has no record: nobody has said what changed
    { id := cid "shipping.orders", revision := 2, kind := some (.extend .backward),
      compat := .declared "adds an optional note field" },
    { id := cid "billing.tax", revision := 2, kind := some .refine, stamp := some "5e11",
      compat := .declared "only renames a field" },
    -- made before the last edit to billing.tax, so it no longer counts
    { id := cid "billing.tax", revision := 2, stamp := some "4d00",
      compat := .tested "tax-v2 vectors, 40 of 40 pass" },
    { id := cid "billing.tax", revision := 2, stamp := some "5e11",
      compat := .refuted "tax-v2 vectors, 3 of 40 fail" } ]

/-- A graph with a missing contract, a cycle and a reference to the future. -/
def broken : Graph where
  contracts := [
    { id := cid "a.one", leanName := "A.one", revision := 1, stamp := "" },
    { id := cid "a.two", leanName := "A.two", revision := 1, stamp := "" } ]
  edges := [
    { src := cid "a.one", kind := .dependsOn, dst := cid "a.two", revision := 1 },
    { src := cid "a.two", kind := .refines, dst := cid "a.one", revision := 1 },
    { src := cid "a.two", kind := .dependsOn, dst := cid "billing.tax", revision := 1 },
    { src := cid "a.one", kind := .dependsOn, dst := cid "a.two", revision := 3 } ]

/-- The default policy plus a shortcut that clears changes without a proof. -/
def loose : Impact.Policy :=
  { Impact.defaultPolicy with
    rules := Impact.defaultPolicy.rules ++ [
      { name := "passing vectors are good enough", head := Impact.verdict "proved",
        body := [Impact.uses (Impact.v "K"), Impact.about "evidence" "tested"] }] }

def report (pol : Impact.Policy) (id : String) (rev : Nat) : IO Impact.Report := do
  IO.println s!"## Impact of {id} moving to @{rev}"
  IO.println ""
  let r := Impact.reason graph pol (cid id) rev
  if r.findings.isEmpty then IO.println "- nothing downstream relies on an older revision"
  for d in r.decided do
    IO.println s!"- **{d.1}: {d.2.1}** ({d.2.2})"
  for f in r.findings do
    let tag := if f.verified then "" else " (NOT VERIFIED)"
    IO.println s!"  - why {f.contract} gets {f.verdict}{tag}:"
    for l in Logic.Why.explain Impact.templates pol.rules "    " f.why do
      IO.println l
  for w in r.waiting do
    IO.println s!"- {w.contract} waits on {w.waitsOn}"
  for i in r.issues do
    IO.println s!"- {i.code} {i.message}"
  IO.println ""
  return r

def decided (r : Impact.Report) : List (String × String × String) :=
  r.decided.map (fun d => (d.1.value, d.2.1, d.2.2))

def sameSet {α : Type} [BEq α] (a b : List α) : Bool :=
  a.length == b.length && a.all b.contains && b.all a.contains

def verified (r : Impact.Report) : Bool :=
  r.complete && r.findings.all (·.verified) && r.waiting.all (·.verified)

/-- Usage: `lake exe impact`. Prints impact reports and the checks, and fails
if any verdict differs from the expected one. -/
def main : IO UInt32 := do
  let pol := Impact.defaultPolicy
  let mut ok := graph.issues.isEmpty && pol.issues.isEmpty
  IO.println "## Revision records"
  IO.println ""
  for i in graph.revisionIssues do
    IO.println s!"- {i.code} {i.message}"
  IO.println ""
  ok := ok && graph.revisionIssues.map (·.code) == ["TR0205", "TR0204"]
  let r1 ← report pol "inventory.stock" 4
  ok := ok && verified r1 && decided r1 == [("shipping.orders", "review", "derived")]
  ok := ok && sameSet (r1.waiting.map (fun w => (w.contract.value, w.waitsOn.value)))
    [("shipping.partial", "shipping.orders"), ("billing.invoices", "shipping.orders")]
  let r2 ← report pol "shipping.orders" 2
  ok := ok && verified r2 && decided r2 == [("billing.invoices", "review", "derived")]
  ok := ok && sameSet (r2.findings.map (·.verdict)) ["review", "confirm"]
  let r3 ← report pol "inventory.stock" 3
  ok := ok && verified r3 && decided r3 == [("shipping.orders", "proved", "proved")]
  ok := ok && r3.waiting.isEmpty
  let r4 ← report pol "billing.tax" 2
  ok := ok && verified r4 && decided r4 == [("billing.invoices", "reprove", "derived")]
  IO.println "## The same change under a policy with an unbacked shortcut"
  IO.println ""
  let r5 ← report loose "inventory.stock" 3
  ok := ok && r5.issues.map (·.code) == ["TR0206"]
  ok := ok && decided r5 == [("shipping.orders", "proved", "derived")]
  IO.println "## Graph checks on a broken graph"
  IO.println ""
  for i in broken.issues do
    IO.println s!"- {i.code} {i.message}"
  ok := ok && broken.issues.map (·.code) == ["TR0201", "TR0202", "TR0202", "TR0203"]
  if ok then
    IO.println ""
    IO.println "ok: impact verdicts and checks as expected"
    return 0
  else
    IO.println "FAIL: a verdict or check differs from what this example expects"
    return 1
