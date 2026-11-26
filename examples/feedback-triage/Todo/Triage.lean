import Todo.Model

/-!
# Feedback reports and triage

A report is what the app attaches when a user says "this is wrong": the
model version, the starting state, the operation names they performed, the
state the app showed, and optionally what the user expected instead. No
free-form personal data.

Triage checks, in order:

1. **malformed:** the report can't be read (a missing or mistyped field).
2. **version-mismatch:** the report names a different model version, so
   replaying it against this model would prove nothing.
3. **model-gap:** the report is well formed, but it shows something the
   model doesn't represent: an operation it doesn't know, or a state field
   it doesn't have. The model needs to grow before the report can be judged.
4. **code-bug:** the app's state breaks a rule or differs from the model.
5. **expectation-mismatch:** the app followed the model; the user expected
   something else.
6. **cannot-reproduce:** the app, the model and the expectation all agree,
   or there is no expectation to compare.
-/

open Lean

namespace Todo

/-- The version reports must name, if they name one. -/
def modelVersion : String := "todo.v1"

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

/-- A user feedback report, once it has been read. -/
structure Report where
  id : String
  version : Option String
  start : List Item
  ops : List OpJson
  observed : List Item
  expected : Option (List Item)
  note : String
  /-- Item objects as sent, to spot fields the model doesn't have. -/
  rawItems : List Json

/-- Read a list of items, keeping the raw objects too. -/
def readItems (j : Json) (field : String) : Except String (List Item × List Json) := do
  let raw ← j.getObjValAs? (Array Json) field
  let items ← raw.toList.mapM (fun r => (fromJson? r : Except String Item))
  return (items, raw.toList)

def Report.ofJson (j : Json) : Except String Report := do
  let id ← j.getObjValAs? String "id"
  let ops ← j.getObjValAs? (Array OpJson) "ops"
  let (observed, rawObserved) ← readItems j "observed"
  let (start, rawStart) ←
    match j.getObjVal? "start" with
    | .ok _ => readItems j "start"
    | .error _ => pure ([], [])
  let (expected, rawExpected) ←
    match j.getObjVal? "expected" with
    | .ok _ => do
      let (e, r) ← readItems j "expected"
      pure (some e, r)
    | .error _ => pure (none, [])
  let version := (j.getObjValAs? String "model").toOption
  let note := (j.getObjValAs? String "note").toOption.getD ""
  return { id, version, start, ops := ops.toList, observed, expected, note,
           rawItems := rawStart ++ rawObserved ++ rawExpected }

/-- The triage outcomes. -/
inductive Triage where
  | malformed
  | versionMismatch
  | modelGap
  | codeBug
  | expectationMismatch
  | cannotReproduce
  deriving Repr, BEq

def Triage.name : Triage → String
  | .malformed => "malformed"
  | .versionMismatch => "version-mismatch"
  | .modelGap => "model-gap"
  | .codeBug => "code-bug"
  | .expectationMismatch => "expectation-mismatch"
  | .cannotReproduce => "cannot-reproduce"

/-- Something the report shows that the model doesn't represent. -/
def gaps (r : Report) : List String :=
  let unknownOps := ((List.range r.ops.length).zip r.ops).filterMap (fun p =>
    match p.2.toOp? with
    | some _ => none
    | none => some s!"operation \"{p.2.op}\" (step {p.1 + 1}) isn't in the model")
  -- An item object with fields beyond `id` and `done` doesn't survive a
  -- round trip through the model's `Item`.
  let unknownFields := r.rawItems.filterMap (fun raw =>
    match (fromJson? raw : Except String Item) with
    | .ok it => if toJson it == raw then none
                else some s!"item {raw.compress} has fields the model doesn't have"
    | .error _ => none)
  unknownOps ++ unknownFields.eraseDups

/-- Replay a report that has been read. -/
def classifyReport (r : Report) : Triage × String :=
  match r.version with
  | some v =>
    if v != modelVersion then
      (.versionMismatch, s!"the report was made with {v}; this model is {modelVersion}")
    else classifyCurrent r
  | none => classifyCurrent r
where
  classifyCurrent (r : Report) : Triage × String :=
    match gaps r with
    | g :: more => (.modelGap, "; ".intercalate (g :: more))
    | [] =>
      match r.ops.mapM OpJson.toOp? with
      | none => (.modelGap, "an operation isn't in the model")
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

/-- Triage a report as received. -/
def classify (j : Json) : Triage × String :=
  match Report.ofJson j with
  | .error e => (.malformed, s!"the report can't be read: {e}")
  | .ok r => classifyReport r

end Todo
