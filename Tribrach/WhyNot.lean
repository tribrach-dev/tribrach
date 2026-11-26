import Tribrach.Logic

/-!
# "Why not?" for the logic layer

`Why.explain` says why a fact holds. This module answers the opposite
question: why a fact does **not** follow, such as "why wasn't this alert
sent?".

For every rule whose conclusion could be the fact, it reports the first
condition that nothing satisfies (with the values already bound), or, if all
conditions hold, the given fact that an "unless" clause found. When the
missing condition is itself something rules derive, it asks "why not?" again,
a few levels deep.

The answer is only meaningful when the search finished (`Result.complete`):
then a condition that nothing matches really does not follow. Like the
engine, this is an untrusted explainer; it makes no claim that `Why.check`
could accept. Each line it prints can be re-checked by querying the same
program.
-/

namespace Tribrach
namespace Logic

/-- Fill in the variables an atom has bindings for, and show the rest as
`?X`. -/
def partialGround (s : Subst) (a : Atom) : Fact :=
  { pred := a.pred
    args := a.args.map (fun t => match t with
      | .const c => c
      | .var x => (s.lookup x).getD s!"?{x}") }

/-- True if some rule concludes the predicate. -/
def derived (rules : List Rule) (pred : String) : Bool :=
  rules.any (fun r => r.head.pred == pred)

/-- Every way to satisfy the first `n` body atoms, starting from `s`. -/
def extend (db : Db) (a : Atom) (ss : List Subst) : List Subst :=
  ss.flatMap (fun s => db.filterMap (fun p => matchAtom s a p.1))

/-- Where one rule stops: the first body atom nothing matches and the
bindings that reached it, or `none` if every body atom can be satisfied. -/
def firstGap (db : Db) : List Atom → List Subst → Option (Atom × List Subst) × List Subst
  | [], ss => (none, ss)
  | a :: rest, ss =>
    let next := extend db a ss
    if next.isEmpty then (some (a, ss), []) else firstGap db rest next

/-- Explain why `goal` does not follow, as a nested Markdown list. `depth`
bounds how many times it asks "why not?" about a missing condition. -/
partial def whyNot (facts : List Fact) (rules : List Rule) (res : Result) (tpl : Templates)
    (goal : Fact) (depth : Nat := 3) (indent : String := "") : List String :=
  if res.db.any (fun p => p.1 == goal) then
    [s!"{indent}- {say tpl goal} does hold; ask why instead"]
  else
    let cands := rules.filterMap (fun r => (matchAtom [] r.head goal).map (fun s => (r, s)))
    if cands.isEmpty then
      if derived rules goal.pred then
        [s!"{indent}- no rule can conclude {say tpl goal} with these values"]
      else
        [s!"{indent}- {say tpl goal} is not given"]
    else
      cands.flatMap (fun (r, s) =>
        match firstGap res.db r.body [s] with
        | (some (a, ss), _) =>
          let pats := (ss.map (fun s' => partialGround s' a)).eraseDups.take 3
          let header := s!"{indent}- rule \"{r.name}\" needs {" or ".intercalate (pats.map (say tpl))}, and nothing says so"
          let deeper :=
            if depth == 0 || !derived rules a.pred then []
            else pats.filter (fun f => !f.args.any (·.startsWith "?")) |>.flatMap
              (fun f => whyNot facts rules res tpl f (depth - 1) (indent ++ "  "))
          header :: deeper
        | (none, full) =>
          let blockers := (full.flatMap (fun s' => r.neg.filterMap (fun a =>
            match ground s' a with
            | some g => if facts.contains g then some g else none
            | none => none))).eraseDups
          if blockers.isEmpty then
            [s!"{indent}- rule \"{r.name}\" applies, but the search did not finish"]
          else
            [s!"{indent}- rule \"{r.name}\" has everything it needs, but it does not apply because {" and ".intercalate (blockers.map (fun g => say tpl g ++ " (given)"))}"])

end Logic
end Tribrach
