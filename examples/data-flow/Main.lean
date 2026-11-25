import DataFlow

open Tribrach.Logic

/-- Usage: `lake exe why`. Answers each question with why trees, re-checks
every tree with the independent checker, and exits non-zero if a tree fails
the check, the search didn't finish, or an answer differs from the expected
one. -/
def main : IO UInt32 := do
  let res := saturate DataFlow.facts DataFlow.rules
  let mut failures : Nat := 0
  if !res.complete then
    IO.println "FAIL the engine ran out of rounds, so \"no\" answers are not complete"
    failures := failures + 1
  for q in DataFlow.questions do
    IO.println s!"## {q.ask}"
    IO.println ""
    let answers := query res q.pattern
    if answers.isEmpty then
      IO.println "**No.** It does not follow from the facts and rules (the search is complete)."
      IO.println ""
    for (_, why) in answers do
      let ok := why.check DataFlow.facts DataFlow.rules
      if !ok then
        failures := failures + 1
      let mark := if ok then "checked" else "FAILED CHECK"
      IO.println s!"**{say DataFlow.templates why.fact}** ({mark})"
      IO.println ""
      for line in why.explain DataFlow.templates do
        IO.println line
      IO.println ""
    let got := answers.map (fun a => a.2.fact.args)
    let want := q.expected
    let same := got.length == want.length && got.all (fun g => want.contains g)
    if !same then
      failures := failures + 1
      IO.println s!"FAIL expected {want}, got {got}"
      IO.println ""
  return (if failures == 0 then 0 else 1)
