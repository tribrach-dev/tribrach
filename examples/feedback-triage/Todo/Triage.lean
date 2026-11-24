import Todo.Model

/-!
# Feedback reports and triage

A report is what the app attaches when a user says "this is wrong": the
starting state, the operation names they performed, the state the app showed,
and optionally what the user expected instead. No free-form personal data.
-/

open Lean

namespace Todo

/-- An operation as it appears in a report. -/
structure OpJson where
  op : String
  id : Nat
  deriving FromJson, ToJson

def OpJson.toOp? (o : OpJson) : Option Op :=
  if o.op == "add" then some (.add o.id)
  else if o.op == "complete" then some (.complete o.id)
  else if o.op == "remove" then some (.remove o.id)
  else none

/-- A user feedback report. -/
structure Report where
  id : String
  start : List Item
  ops : List OpJson
  observed : List Item
  expected : Option (List Item)
  note : String
  /-- The triage this example expects, so CI can check the classifier. -/
  triage : Option String

def Report.ofJson (j : Json) : Except String Report := do
  let id ← j.getObjValAs? String "id"
  let ops ← j.getObjValAs? (Array OpJson) "ops"
  let observed ← j.getObjValAs? (Array Item) "observed"
  let start := ((j.getObjValAs? (Array Item) "start").toOption.getD #[]).toList
  let expected := (j.getObjValAs? (Array Item) "expected").toOption.map (·.toList)
  let note := (j.getObjValAs? String "note").toOption.getD ""
  let triage := (j.getObjValAs? String "triage").toOption
  return { id, start, ops := ops.toList, observed := observed.toList, expected, note, triage }

/-- The three triage outcomes. -/
inductive Triage where
  | codeBug
  | expectationMismatch
  | cannotReproduce
  deriving Repr, BEq

def Triage.name : Triage → String
  | .codeBug => "code-bug"
  | .expectationMismatch => "expectation-mismatch"
  | .cannotReproduce => "cannot-reproduce"

/-- Replay the report against the model and sort it. -/
def classify (r : Report) : Triage × String :=
  match r.ops.mapM OpJson.toOp? with
  | none => (.cannotReproduce, "the report has an operation the model doesn't know")
  | some ops =>
    let model := run r.start ops
    if !uniqueIds r.observed then
      (.codeBug, "the app's state breaks the unique-id rule")
    else if model != r.observed then
      (.codeBug, s!"the app's state differs from the model after {ops.length} operations")
    else
      match r.expected with
      | some e =>
        if e != model then
          (.expectationMismatch, "the app followed the rules; the user expected something else")
        else
          (.cannotReproduce, "the app, the model and the user's expectation all agree")
      | none => (.cannotReproduce, "no expectation given and the app matches the model")

end Todo
