import Bench.Irrigation
import Bench.Library
import Bench.Notify
import Bench.Access
import Bench.Deploy
import Tribrach.WhyNot

open Lean Tribrach.Logic Bench

def models : List BenchModel := [Irrigation.model, Library.model, Notify.model, Access.model, Deploy.model]

def usage : String := "usage:
  why expect <model> <inputs.json>               print test vectors (expected decisions) as JSON
  why <model> <vectors.json> <id>                the expected decisions for one case, each with its why tree
  why <model> <vectors.json> <id> facts          the given facts for that case
  why <model> <vectors.json> <id> why <pred> [args...]
  why <model> <vectors.json> <id> whynot <pred> [args...]"

def readCases (path : String) : IO (Array Json) := do
  let s ← IO.FS.readFile path
  match Json.parse s >>= (·.getArr?) with
  | .ok a => return a
  | .error e => throw (IO.userError s!"{path}: {e}")

def ioOf {α} (r : Except String α) : IO α :=
  match r with
  | .ok a => return a
  | .error e => throw (IO.userError e)

def findModel (name : String) : IO BenchModel :=
  match models.find? (·.name == name) with
  | some m => return m
  | none => throw (IO.userError s!"unknown model {name}; known: {models.map (·.name)}")

def expect (m : BenchModel) (path : String) : IO Unit := do
  let cases ← readCases path
  let out ← cases.mapM (fun cj => do
    let id ← ioOf (getStr cj "id")
    let input ← ioOf (cj.getObjVal? "input")
    let (_, res) ← ioOf (m.run input)
    if !res.complete then throw (IO.userError s!"{id}: search did not finish")
    let outs := (m.outcomes res).map (fun p => Json.str p.1)
    return Json.mkObj [("id", Json.str id), ("input", input), ("expected", Json.arr outs.toArray)])
  IO.println (Json.arr out).pretty

def explainCase (m : BenchModel) (path id : String) (rest : List String) : IO UInt32 := do
  let cases ← readCases path
  let some cj := cases.find? (fun cj => (getStr cj "id").toOption == some id)
    | IO.eprintln s!"no case {id} in {path}"; return 2
  let input ← ioOf (cj.getObjVal? "input")
  let (facts, res) ← ioOf (m.run input)
  if !res.complete then
    IO.println "the search did not finish; answers may be incomplete"; return 1
  match rest with
  | [] =>
    let outs := m.outcomes res
    IO.println s!"Expected decisions for {id}: {if outs.isEmpty then "none" else ", ".intercalate (outs.map (·.1))}"
    IO.println "(the search finished, so any decision not listed does not follow; ask `whynot` for one)"
    for (_, w) in outs do
      let ok := w.check facts m.rules
      IO.println ""
      for l in w.explain m.templates m.rules do IO.println l
      if !ok then IO.println "  (FAILED the independent check)"
    return 0
  | ["facts"] =>
    IO.println s!"Given facts for {id}:"
    for f in facts do IO.println s!"- {say m.templates f}"
    return 0
  | "why" :: pred :: args =>
    let goal : Fact := { pred, args }
    match res.db.find? (fun p => p.1 == goal) with
    | some (_, w) =>
      for l in w.explain m.templates m.rules do IO.println l
      if !(w.check facts m.rules) then IO.println "  (FAILED the independent check)"
    | none =>
      IO.println s!"{say m.templates goal} does not follow. Why not:"
      for l in whyNot facts m.rules res m.templates goal do IO.println l
    return 0
  | "whynot" :: pred :: args =>
    let goal : Fact := { pred, args }
    for l in whyNot facts m.rules res m.templates goal do IO.println l
    return 0
  | _ => IO.eprintln usage; return 2

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["expect", name, path] => expect (← findModel name) path; return 0
    | name :: path :: id :: rest => explainCase (← findModel name) path id rest
    | _ => IO.eprintln usage; return 2
  catch e =>
    IO.eprintln s!"error: {e}"; return 1
