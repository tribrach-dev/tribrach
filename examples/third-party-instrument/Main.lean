import Tribrach.Package

open Tribrach

/-- Links as an exported manifest would list them. `owner` is the raw
manifest field: an instrument id, or a legacy name. -/
def manifest : List (String × String × String) := [
  ("Counter.counterStep", "acme.kotlin", "com.example.counter.step"),
  ("Counter.counterStep", "tribrach.go", "example.com/counter.Step"),
  ("Counter.counterStep", "go", "example.com/counter.Step"),
  ("Counter.counterStep", "swift", "Counter.step(_:)")
]

/-- Usage: `lake exe owners <descriptor>...`. Reads the descriptors,
registers the ids they own, resolves every link in `manifest`, and checks the
diagnostics against what this fixture expects. -/
def main (paths : List String) : IO UInt32 := do
  let mut descriptors : List Descriptor := []
  let mut diags : List Diagnostic := []
  for p in paths do
    match Descriptor.parse p (← IO.FS.readFile p) with
    | .ok d => descriptors := descriptors ++ [d]
    | .error d => diags := diags ++ [d]
  let reg := Registry.build descriptors
  diags := diags ++ reg.diagnostics
  let mut owners : List String := []
  for (lean, ownerField, symbol) in manifest do
    match ownerOfManifest? ownerField with
    | none =>
      let msg := "link owner " ++ ownerField ++ " is not an instrument id"
      let d : Diagnostic := { code := "TR0103", message := msg, hint := "Use publisher.name, for example tribrach.go" }
      diags := diags ++ [d]
    | some (id, legacy) =>
      if legacy then
        IO.println s!"note: `{ownerField}` is a legacy owner name; write `{id}` instead"
      match reg.resolve { leanName := lean, owner := id, symbol, stamp := "" } with
      | .ok pkg =>
        IO.println s!"{lean} -> {symbol}: owned by {pkg} ({id})"
        owners := owners ++ [pkg]
      | .error d => diags := diags ++ [d]
  for d in diags do
    IO.println d.render
  -- What this fixture must show: the third-party instrument owns its link
  -- without any change to core, a legacy name still resolves, and each
  -- problem gets its own code.
  let codes := diags.map (·.code)
  let ok := owners == ["acme-kotlin", "tribrach-go", "tribrach-go"]
    && codes == ["TR0103", "TR0102", "TR0101"]
  if ok then
    IO.println "ok: ownership and diagnostics as expected"
    return 0
  else
    IO.println s!"FAIL: owners {owners}, diagnostic codes {codes}"
    return 1
