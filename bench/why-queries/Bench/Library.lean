import Bench.Common

/-!
# Library lending desk (specification)

Input: one member at the desk and the items they want to borrow.

```json
{"member": {"id": "m1", "age": 15, "status": "active", "fines_cents": 200,
            "loans": 3, "tier": "standard"},
 "items": [{"id": "i1", "kind": "book", "rating": "teen",
            "status": "on_shelf", "held_for": null}]}
```

`status` of a member is `active`, `suspended` or `expired`. An item's
`kind` is `book`, `dvd`, `periodical` or `reference`; its `rating` is
`all`, `teen` or `adult`; its `status` is `on_shelf`, `on_hold` (waiting for
the member in `held_for`) or `out`.

Decision: `lend M I` (member M may take item I home).
-/

namespace Bench.Library

open Tribrach.Logic
open Lean (Json)

/-- Fines at or above this (cents) block borrowing. -/
def finesBlockAt : Int := 500

/-- How many items a member may have out at once. -/
def loanLimit : String → Int
  | "plus" => 10
  | _ => 5

def teenAge : Int := 13
def adultAge : Int := 18

def encodeItem (i : Json) : Except String (List Fact) := do
  let id ← getStr i "id"
  let kind ← getStr i "kind"
  let rating ← getStr i "rating"
  let status ← getStr i "status"
  let heldFor : Option String := (i.getObjValAs? String "held_for").toOption
  return [fact "item" [id, kind], fact "rating" [id, rating]] ++
    when (status == "on_shelf") (fact "on_shelf" [id]) ++
    when (kind == "reference") (fact "reference" [id]) ++
    (match status, heldFor with
     | "on_hold", some m => [fact "held_for" [id, m]]
     | _, _ => [])

def encode (j : Json) : Except String (List Fact) := do
  let m ← j.getObjVal? "member"
  let id ← getStr m "id"
  let age ← getInt m "age"
  let status ← getStr m "status"
  let fines ← getInt m "fines_cents"
  let loans ← getInt m "loans"
  let tier ← getStr m "tier"
  let items ← getArr j "items"
  let is ← items.toList.mapM encodeItem
  let lim := loanLimit tier
  return [fact "member" [id], fact "age" [id, toString age], fact "fines" [id, toString fines],
          fact "loans" [id, toString loans, toString lim]] ++
    when (status == "active") (fact "active" [id]) ++
    when (fines ≥ finesBlockAt) (fact "owes_too_much" [id]) ++
    when (loans ≥ lim) (fact "at_limit" [id]) ++
    when (age ≥ teenAge) (fact "teen_or_older" [id, toString age]) ++
    when (age ≥ adultAge) (fact "adult" [id, toString age]) ++
    is.flatten

def rules : List Rule := [
  { name := "good standing"
    head := atom "eligible" [v "M"], body := [atom "active" [v "M"]]
    neg := [atom "owes_too_much" [v "M"], atom "at_limit" [v "M"]] },
  { name := "rated for all ages"
    head := atom "age_ok" [v "M", v "I"]
    body := [atom "member" [v "M"], atom "rating" [v "I", c "all"]] },
  { name := "rated teen"
    head := atom "age_ok" [v "M", v "I"]
    body := [atom "teen_or_older" [v "M", v "A"], atom "rating" [v "I", c "teen"]] },
  { name := "rated adult"
    head := atom "age_ok" [v "M", v "I"]
    body := [atom "adult" [v "M", v "A"], atom "rating" [v "I", c "adult"]] },
  { name := "on the shelf"
    head := atom "available" [v "I", v "M"]
    body := [atom "on_shelf" [v "I"], atom "member" [v "M"]]
    neg := [atom "reference" [v "I"]] },
  { name := "held for this member"
    head := atom "available" [v "I", v "M"]
    body := [atom "held_for" [v "I", v "M"]] },
  { name := "lend"
    head := atom "lend" [v "M", v "I"]
    body := [atom "eligible" [v "M"], atom "available" [v "I", v "M"], atom "age_ok" [v "M", v "I"]] }
]

def templates : Templates := [
  ("member", "$1 is the member at the desk"),
  ("age", "$1 is $2 years old"),
  ("fines", "$1 owes $2 cents in fines"),
  ("loans", "$1 has $2 items out (limit $3)"),
  ("active", "$1's membership is active"),
  ("owes_too_much", "$1 owes 500 cents or more"),
  ("at_limit", "$1 is at their loan limit"),
  ("teen_or_older", "$1 is 13 or older (age $2)"),
  ("adult", "$1 is 18 or older (age $2)"),
  ("item", "$1 is a $2"),
  ("rating", "$1 is rated $2"),
  ("on_shelf", "$1 is on the shelf"),
  ("reference", "$1 is reference-only"),
  ("held_for", "$1 is on hold for $2"),
  ("eligible", "$1 may borrow"),
  ("age_ok", "$1 is old enough for $2"),
  ("available", "$2 can take $1"),
  ("lend", "lend $1 item $2")
]

def model : BenchModel :=
  { name := "library", encode, rules, templates, decisions := ["lend"] }

end Bench.Library
