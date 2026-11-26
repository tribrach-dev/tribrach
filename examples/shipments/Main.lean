import Shipments

open Shipments Tribrach

def showOrder (s : Order) : String :=
  s!"{s.shipped}/{s.ordered} shipped" ++ (if s.cancelled then ", cancelled" else "")

def showOut (s : Order) : Out → String
  | .done s' => s!"done: {showOrder s'}" ++ (if s' == s then " (no change)" else "")
  | .refused => "refused"
  | .failed .outOfStock => "failed: out of stock"

def showOp : Shipments.Op → String
  | .ship n => s!"ship {n}"
  | .cancel => "cancel"

/-- Every outcome worth trying for a request: each shipped count up to the
order size, cancelling, refusing and failing. -/
def candidates (s : Order) : List Out :=
  ((List.range (s.ordered + 1)).map (fun k => Outcome.done { s with shipped := k })) ++
    [.done { s with cancelled := true }, .refused, .failed .outOfStock]

/-- Observed transitions, as replay vectors, and whether each should pass. -/
def vectors : List (Order × Shipments.Op × Out × Bool) :=
  let fresh : Order := { ordered := 5, shipped := 0, cancelled := false }
  [ (fresh, .ship 3, .done { fresh with shipped := 3 }, true),
    (fresh, .ship 3, .done { fresh with shipped := 1 }, true),
    (fresh, .ship 3, .failed .outOfStock, true),
    (fresh, .ship 6, .refused, true),
    (fresh, .ship 6, .done { fresh with shipped := 5 }, false),
    (fresh, .ship 3, .done { fresh with shipped := 4 }, false),
    (fresh, .ship 3, .refused, false),
    ({ fresh with shipped := 5 }, .cancel, .refused, true),
    ({ fresh with shipped := 2 }, .cancel, .done { fresh with shipped := 2, cancelled := true }, true),
    ({ fresh with cancelled := true }, .ship 1, .refused, true) ]

/-- Usage: `lake exe replay`. Lists every allowed outcome of one request, then
replays the vectors and fails if any verdict differs from the expected one. -/
def main : IO UInt32 := do
  let fresh : Order := { ordered := 5, shipped := 0, cancelled := false }
  IO.println s!"Allowed outcomes of `ship 3` on an order at {showOrder fresh}:"
  for out in candidates fresh do
    if allowedB (.ship 3) fresh out then
      IO.println s!"  - {showOut fresh out}"
  IO.println ""
  IO.println "Replaying vectors (each shows only that one outcome was allowed):"
  let mut failures : Nat := 0
  for (s, o, out, want) in vectors do
    let got := allowedB o s out
    let mark := if got == want then "ok  " else "FAIL"
    if got != want then failures := failures + 1
    let verdict := if got then "allowed" else "rejected"
    IO.println s!"{mark} {showOrder s}, {showOp o} -> {showOut s out}: {verdict}"
  return (if failures == 0 then 0 else 1)
