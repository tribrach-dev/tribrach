import CaptureSchema

/-!
Runs the Lean side of two checks (see check.sh):

* every pattern in `Pat.all` against `tests/conformance/patterns.json`: the
  case must exist, carry the regex and the tree Lean exports, and the Lean
  checker must accept and reject exactly the listed strings;
* the capture schema's Lean checker against the capture goldens: everything
  in `valid/` accepted, everything in `invalid/` rejected.

Run with `lake env lean --run Check.lean <repo root>`. With
`fuzz <in> <out>` it instead writes the Lean verdicts for generated strings,
which check.sh compares with the regexes. With `trees <out>` it writes each
pattern's tree, by name, for updating `patterns.json`.
-/

open Lean Tribrach.Schema

def readJson (p : System.FilePath) : IO Json := do
  match Json.parse (← IO.FS.readFile p) with
  | .ok j => pure j
  | .error e => throw (IO.userError s!"{p}: {e}")

def strings (j : Json) (k : String) : List String :=
  match j.getObjValAs? (List String) k with
  | .ok xs => xs
  | .error _ => []

def checkPatterns (root : System.FilePath) : IO Bool := do
  let doc ← readJson (root / "tests" / "conformance" / "patterns.json")
  let cases := (doc.getObjValAs? (List Json) "cases").toOption.getD []
  let mut ok := true
  for p in Pat.all do
    match cases.find? (fun c => (c.getObjValAs? String "name").toOption == some p.name) with
    | none =>
      IO.println s!"FAIL patterns: no case for {p.name}"; ok := false
    | some c =>
      if (c.getObjValAs? String "regex").toOption != some p.regex then
        IO.println s!"FAIL patterns: {p.name} regex differs from Pat.regex"; ok := false
      if c.getObjValD "tree" != p.tree.toJson then
        IO.println s!"FAIL patterns: {p.name} tree differs from Pat.tree; it is {p.tree.toJson.compress}"
        ok := false
      for s in strings c "accept" do
        if !p.check s then IO.println s!"FAIL patterns: {p.name} should accept {repr s}"; ok := false
      for s in strings c "reject" do
        if p.check s then IO.println s!"FAIL patterns: {p.name} should reject {repr s}"; ok := false
  if ok then IO.println s!"ok   patterns: Lean agrees on all {Pat.all.length} patterns"
  return ok

def checkGoldens (root : System.FilePath) : IO Bool := do
  let mut ok := true
  for (folder, want) in [("valid", true), ("invalid", false)] do
    let dir := root / "tests" / "captures" / folder
    let files := (← dir.readDir).map (·.path) |>.qsort (·.toString < ·.toString)
    for f in files do
      let problems := CaptureSchema.schema.problems (← readJson f)
      let got := problems.isEmpty
      let name := s!"captures/{folder}/{f.fileName.getD ""}"
      if got == want then
        IO.println s!"ok   {name}{if problems.isEmpty then "" else s!" ({", ".intercalate problems})"}"
      else
        IO.println s!"FAIL {name}: Lean {if got then "accepts" else "rejects"} it"; ok := false
  return ok

/-- `fuzz in out`: for each pattern name in `in` (an object of string
lists), write the Lean checker's verdicts to `out`. -/
def fuzz (inp out : System.FilePath) : IO UInt32 := do
  let doc ← readJson inp
  let verdicts := Pat.all.map fun p =>
    (p.name, Json.arr ((strings doc p.name).map fun s => Json.bool (p.check s)).toArray)
  IO.FS.writeFile out (Json.mkObj verdicts).compress
  return 0

def main (args : List String) : IO UInt32 := do
  if let ["fuzz", inp, out] := args then return ← fuzz inp out
  if let ["trees", out] := args then
    IO.FS.writeFile out (Json.mkObj (Pat.all.map fun p => (p.name, p.tree.toJson))).pretty
    return 0
  let root : System.FilePath := args.headD "../.."
  let a ← checkPatterns root
  let b ← checkGoldens root
  return if a && b then 0 else 1
