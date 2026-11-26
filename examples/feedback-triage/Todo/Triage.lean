import Tribrach.Triage
import Todo.Model

/-!
# Triage for the to-do model

Everything triage needs from this project: the model, its version, and how
its states and operations look in a report. The replay, the six verdicts and
the report format come from `Tribrach.Triage`.
-/

open Lean Tribrach

namespace Todo

/-- The to-do list as a Tribrach model: item ids are unique. -/
def model : Model where
  State := List Item
  Inv := fun s => uniqueIds s = true
  Op := Op
  step := step

def decodeItems (j : Json) : Except String (List Item) := do
  let arr ← j.getArr?
  arr.toList.mapM (fun r => (fromJson? r : Except String Item))

def encodeItems (s : List Item) : Json := toJson s

def sameItems (a b : List Item) : Bool := a == b

def brokenRules (s : List Item) : List String :=
  if uniqueIds s then [] else ["the unique-id rule"]

/-- Operations appear in reports as `{"op": "add", "id": 3}`. -/
def decodeOp (j : Json) : Triage.Decoded Op :=
  match j.getObjValAs? String "op" with
  | .error e => .malformed e
  | .ok name =>
    if name == "add" || name == "complete" || name == "remove" then
      match j.getObjValAs? Nat "id" with
      | .error e => .malformed s!"{name}: {e}"
      | .ok i =>
        if name == "add" then .ok (.add i)
        else if name == "complete" then .ok (.complete i)
        else .ok (.remove i)
    else .unknown name

def subject : Triage.Subject model where
  version := "todo.v1"
  initial := ([] : List Item)
  equal := sameItems
  broken := brokenRules
  sound := fun s h => by
    show uniqueIds s = true
    cases hu : uniqueIds s with
    | true => rfl
    | false => simp [brokenRules, hu] at h
  decodeState := decodeItems
  encodeState := encodeItems
  decodeOp := decodeOp

end Todo
