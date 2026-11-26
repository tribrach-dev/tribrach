import Todo.Triage

open Lean

/-- Usage: `lake exe triage reports.json`. Prints one line per report and
exits non-zero if any report's expected triage doesn't match. -/
def main (args : List String) : IO UInt32 := do
  let path := args.headD "reports.json"
  let text ← IO.FS.readFile path
  match Json.parse text >>= fun j => j.getArr? with
  | .error e => do
    IO.eprintln s!"cannot read {path}: {e}"
    return 2
  | .ok arr => do
    let mut failures : Nat := 0
    for j in arr do
      -- Read the id and expected triage leniently, so malformed reports
      -- can still be listed and checked.
      let id := (j.getObjValAs? String "id").toOption.getD "(no id)"
      let want := (j.getObjValAs? String "triage").toOption
      let (t, why) := Todo.classify j
      let mark := match want with
        | some w => if w == t.name then "ok  " else "FAIL"
        | none => "    "
      if mark == "FAIL" then
        failures := failures + 1
      IO.println s!"{mark} {id}: {t.name} ({why})"
    return (if failures == 0 then 0 else 1)
