import Lean.Data.Json
import Std.Data.TreeMap.Raw
import Tribrach.Model

/-!
# Feedback triage

A user says "this is wrong" and the app attaches a **report**: the model
version, the starting state, the operations they performed, the state the
app showed, and optionally what the user expected instead. Triage replays the
report against a `Model` and sorts it into one of six verdicts, checked in
this order:

1. **malformed:** the report can't be read (a missing or mistyped field).
2. **version-mismatch:** the report names another model version, so replaying
   it against this one would prove nothing.
3. **model-gap:** the report is well formed but shows something the model
   doesn't represent: an operation it doesn't know, or a state field it
   doesn't have. The model needs to grow before the report can be judged.
4. **code-bug:** the app's state breaks a rule, or differs from the model.
5. **expectation-mismatch:** the app followed the model; the user expected
   something else.
6. **cannot-reproduce:** the app, the model and the expectation all agree, or
   there is no expectation to compare.

## Using it in a project

A project supplies a `Subject` for its model: the version string, how to read
and write states and operations as JSON, and an executable rule check that is
proved to agree with the model's invariant (`sound`). Nothing else is
project-specific:

```lean
def subject : Triage.Subject myModel := { version := "orders.v3", … }
def main (args : List String) : IO UInt32 :=
  Triage.runFile subject (args.headD "reports.json")
```

## Report format

```json
{ "id": "r1", "model": "orders.v3", "note": "free text from the user",
  "start": <state>, "ops": [<op>, …], "observed": <state>,
  "expected": <state>, "triage": "code-bug" }
```

`model`, `start`, `expected`, `note` and `triage` are optional. A missing
`start` means the subject's initial state. `triage` is the verdict the report
should get, so a project can keep sample reports as regression tests.

State fields the model doesn't have are found by reading each state and
writing it back: any key that doesn't survive the round trip is named in the
evidence, such as `observed[0].pinned`.
-/

open Lean

namespace Tribrach
namespace Triage

/-- An operation read from a report. -/
inductive Decoded (α : Type) where
  | ok (op : α)
  /-- Well formed, but not an operation the model has. -/
  | unknown (name : String)
  | malformed (why : String)

/-- What a project supplies to triage reports against its model. -/
structure Subject (m : Model) where
  /-- The version reports must name, if they name one. -/
  version : String
  /-- The state a report starts from when it gives none. -/
  initial : m.State
  equal : m.State → m.State → Bool
  /-- The rules a state breaks, by name. Empty means it keeps them all. -/
  broken : m.State → List String
  /-- The executable check agrees with the model's invariant. -/
  sound : ∀ s, broken s = [] → m.Inv s
  decodeState : Json → Except String m.State
  encodeState : m.State → Json
  decodeOp : Json → Decoded m.Op

inductive Verdict where
  | malformed
  | versionMismatch
  | modelGap
  | codeBug
  | expectationMismatch
  | cannotReproduce
  deriving Repr, BEq, DecidableEq

def Verdict.name : Verdict → String
  | .malformed => "malformed"
  | .versionMismatch => "version-mismatch"
  | .modelGap => "model-gap"
  | .codeBug => "code-bug"
  | .expectationMismatch => "expectation-mismatch"
  | .cannotReproduce => "cannot-reproduce"

/-- A report once it has been read. -/
structure Report (m : Model) where
  id : String
  version : Option String
  start : m.State
  ops : List (Decoded m.Op)
  observed : m.State
  expected : Option m.State
  note : String
  /-- State fields in the report that the model doesn't have. -/
  fieldGaps : List String

/-- Keys in `sent` that don't survive the round trip to `back`. -/
partial def lostKeys (path : String) (sent back : Json) : List String :=
  match sent, back with
  | .obj kvs, .obj _ =>
    kvs.foldl (fun acc k v =>
      match back.getObjVal? k with
      | .ok v' => acc ++ lostKeys s!"{path}.{k}" v v'
      | .error _ => acc ++ [s!"{path}.{k} isn't in the model"]) []
  | .arr xs, .arr ys =>
    let pairs := xs.toList.zip ys.toList
    ((List.range pairs.length).zip pairs).flatMap (fun p =>
      lostKeys s!"{path}[{p.1}]" p.2.1 p.2.2)
  | _, _ => []

/-- Read one state field, with the keys the model drops. -/
def readState {m : Model} (sub : Subject m) (j : Json) (field : String) :
    Except String (Option (m.State × List String)) :=
  match j.getObjVal? field with
  | .error _ => pure none
  | .ok sj => do
    let s ← (sub.decodeState sj).mapError (fun e => s!"{field}: {e}")
    pure (some (s, lostKeys field sj (sub.encodeState s)))

def Report.read {m : Model} (sub : Subject m) (j : Json) : Except String (Report m) := do
  let id ← j.getObjValAs? String "id"
  let opsJ ← j.getObjValAs? (Array Json) "ops"
  let ops ← ((List.range opsJ.size).zip opsJ.toList).mapM (fun p =>
    match sub.decodeOp p.2 with
    | .malformed e => throw s!"operation {p.1 + 1}: {e}"
    | d => pure d)
  let some (observed, gObs) ← readState sub j "observed"
    | throw "the report has no observed state"
  let start ← readState sub j "start"
  let expected ← readState sub j "expected"
  let version := (j.getObjValAs? String "model").toOption
  let note := (j.getObjValAs? String "note").toOption.getD ""
  let gStart := (start.map (·.2)).getD []
  let gExp := (expected.map (·.2)).getD []
  return { id, version, ops, observed, note,
           start := (start.map (·.1)).getD sub.initial,
           expected := expected.map (·.1),
           fieldGaps := (gStart ++ gObs ++ gExp).eraseDups }

/-- What the report shows that the model doesn't represent. -/
def Report.gaps {m : Model} (r : Report m) : List String :=
  let ops := ((List.range r.ops.length).zip r.ops).filterMap (fun p =>
    match p.2 with
    | .unknown name => some s!"operation \"{name}\" (step {p.1 + 1}) isn't in the model"
    | _ => none)
  ops ++ r.fieldGaps

/-- The operations, when every one of them is in the model. -/
def Report.knownOps {m : Model} (r : Report m) : List m.Op :=
  r.ops.filterMap (fun d => match d with | .ok o => some o | _ => none)

/-- Replay a report that has been read and model-checked for gaps. -/
def judge {m : Model} (sub : Subject m) (r : Report m) : Verdict × String :=
  let ops := r.knownOps
  let model := m.run ops r.start
  match sub.broken r.observed with
  | rule :: _ => (.codeBug, s!"the app's state breaks {rule}")
  | [] =>
    if !sub.equal model r.observed then
      (.codeBug, s!"the app's state differs from the model after {ops.length} operations")
    else
      match r.expected with
      | some e =>
        if !sub.equal e model then
          (.expectationMismatch, "the app followed the rules; the user expected something else")
        else
          (.cannotReproduce, "the app, the model and the user's expectation all agree")
      | none => (.cannotReproduce, "no expectation given and the app matches the model")

def Report.classify {m : Model} (sub : Subject m) (r : Report m) : Verdict × String :=
  let afterVersion : Verdict × String :=
    match r.gaps with
    | g :: more => (.modelGap, "; ".intercalate (g :: more))
    | [] => judge sub r
  match r.version with
  | some v =>
    if v != sub.version then
      (.versionMismatch, s!"the report was made with {v}; this model is {sub.version}")
    else afterVersion
  | none => afterVersion

/-- Triage a report as received. -/
def classify {m : Model} (sub : Subject m) (j : Json) : Verdict × String :=
  match Report.read sub j with
  | .error e => (.malformed, s!"the report can't be read: {e}")
  | .ok r => r.classify sub

/-- When triage finds no broken rule, the app's state really keeps the
model's invariant, so a later verdict (differs from the model, expectation
mismatch, cannot reproduce) is never hiding a rule violation. -/
theorem kept_rules {m : Model} (sub : Subject m) (r : Report m)
    (h : sub.broken r.observed = []) : m.Inv r.observed :=
  sub.sound _ h

/-- Read a JSON array of reports, print one line each, and return 1 if any
report's `triage` field disagrees with its verdict (2 if the file can't be
read). Suitable as a project's `main`. -/
def runFile {m : Model} (sub : Subject m) (path : String) : IO UInt32 := do
  let text ← IO.FS.readFile path
  match Json.parse text >>= fun j => j.getArr? with
  | .error e => do
    IO.eprintln s!"cannot read {path}: {e}"
    return 2
  | .ok arr => do
    let mut failures : Nat := 0
    for j in arr do
      -- Read the id and expected verdict leniently, so malformed reports
      -- can still be listed and checked.
      let id := (j.getObjValAs? String "id").toOption.getD "(no id)"
      let want := (j.getObjValAs? String "triage").toOption
      let (t, why) := classify sub j
      let mark := match want with
        | some w => if w == t.name then "ok  " else "FAIL"
        | none => "    "
      if mark == "FAIL" then
        failures := failures + 1
      IO.println s!"{mark} {id}: {t.name} ({why})"
    return (if failures == 0 then 0 else 1)

end Triage
end Tribrach
