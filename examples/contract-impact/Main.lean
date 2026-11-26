import Tribrach.Contract

open Tribrach

def cid (s : String) : ContractId := ⟨s⟩

/-- Two domains: shipping (with its inventory) and billing. -/
def graph : Graph where
  contracts := [
    { id := cid "inventory.stock", leanName := "Inventory.stock", revision := 4, stamp := "a41f" },
    -- Renamed from `Shipping.OrderBook`; its id, and every reference to it, stayed the same.
    { id := cid "shipping.orders", leanName := "Shipping.Orders", revision := 2, stamp := "77c0" },
    { id := cid "shipping.partial", leanName := "Shipping.partialShipments", revision := 1, stamp := "19be" },
    { id := cid "billing.invoices", leanName := "Billing.invoices", revision := 1, stamp := "c3d2" } ]
  edges := [
    { src := cid "shipping.orders", kind := .dependsOn, dst := cid "inventory.stock", revision := 2 },
    { src := cid "shipping.partial", kind := .refines, dst := cid "shipping.orders", revision := 2 },
    { src := cid "billing.invoices", kind := .dependsOn, dst := cid "shipping.orders", revision := 1 } ]
  history := [
    { id := cid "inventory.stock", revision := 3, compat := .checked "theorem Inventory.stock_v3_refines_v2" },
    -- revision 4 has no record: a structural change nobody has assessed yet
    { id := cid "shipping.orders", revision := 2, compat := .declared "adds an optional note field" } ]

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

def rank (c : Compat) : String :=
  match c with
  | .structural => "review"
  | .declared _ => "declared"
  | .checked _ => "checked"

def report (g : Graph) (id : String) (rev : Nat) : IO (List (String × String)) := do
  IO.println s!"## Impact of {id} moving to @{rev}"
  IO.println ""
  let items := g.impact (cid id) rev
  if items.isEmpty then IO.println "- nothing downstream relies on an older revision"
  for i in items do
    let lead := match i.through with
      | none => s!"{i.contract} ({i.kind.name} {id})"
      | some t => s!"{i.contract} ({i.kind.name} {t}, indirect)"
    IO.println s!"- {lead}: {i.text}"
  IO.println ""
  return items.map (fun i => (i.contract.value, rank i.compat))

/-- Usage: `lake exe impact`. Prints impact reports for two upstream changes
and the graph checks, and fails if any verdict differs from the expected one. -/
def main : IO UInt32 := do
  let mut ok := graph.issues.isEmpty
  let r1 ← report graph "inventory.stock" 4
  ok := ok && r1 == [("shipping.orders", "review"), ("shipping.partial", "review"),
                     ("billing.invoices", "review")]
  let r2 ← report graph "shipping.orders" 2
  ok := ok && r2 == [("billing.invoices", "declared")]
  let r3 ← report graph "inventory.stock" 3
  ok := ok && r3 == [("shipping.orders", "checked")]
  IO.println "## Graph checks on a broken graph"
  IO.println ""
  for i in broken.issues do
    IO.println s!"- {i.code} {i.message}"
  ok := ok && broken.issues.map (·.code) == ["TR0201", "TR0202", "TR0202", "TR0203"]
  if ok then
    IO.println ""
    IO.println "ok: impact verdicts and graph checks as expected"
    return 0
  else
    IO.println "FAIL: a verdict or check differs from what this example expects"
    return 1
