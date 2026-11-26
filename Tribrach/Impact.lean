import Tribrach.Model
import Tribrach.Contract
import Tribrach.Logic

/-!
# Impact of a contract change, proved or derived

When a contract moves to a new revision, every contract that relied on an
older one gets a verdict, and each verdict comes with a why tree that the
small checker in `Tribrach.Logic` re-verifies.

There are two kinds of verdict:

- **Proved.** The change is cleared by a theorem. Today there is one:
  `Model.carry_over`, which says a checked refinement keeps every guarantee
  a `dependsOn` dependent used.
- **Derived.** A policy rule raised a concern: review, confirm a claim,
  re-prove, or plan a move off a deprecated revision.

## Conflict rules

- Only a rule backed by a theorem may conclude `proved`. Any other rule is
  policy and may only ask for more work. `Policy.issues` reports a clearing
  rule without a theorem (`TR0206`), and `cleared_only_by_backed` proves
  that every checked `proved` fact came from a backed rule.
- When a proved verdict and a policy concern meet on the same edge, the
  proof decides and the disagreement is reported (`TR0207`).
- Records that disagree about one revision (`TR0204`) and stale records
  (`TR0205`) are resolved in `Tribrach.Contract` before any rule runs.
-/

namespace Tribrach

/-! ## The proved side -/

namespace Model

/-- `newer` keeps every guarantee `older` gives: each state of `newer` can be
read as a state of `older`, and `newer`'s rules imply `older`'s. -/
structure Strengthens (newer older : Model) where
  view : newer.State → older.State
  inv : ∀ s, newer.Inv s → older.Inv (view s)

/-- **Carry-over.** If `newer` strengthens `older` and keeps its own rules,
then anything a dependent derived from `older`'s rules still holds after any
sequence of `newer`'s operations. -/
theorem carry_over {newer older : Model} (r : Strengthens newer older)
    (hnew : newer.Preserves) {P : older.State → Prop} (uses : ∀ s, older.Inv s → P s) :
    ∀ (ops : List newer.Op) (s : newer.State), newer.Inv s → P (r.view (newer.run ops s)) :=
  fun ops s hs => uses _ (r.inv _ (newer.run_preserves hnew ops s hs))

end Model

namespace Impact

open Logic

def c (s : String) : Term := .const s
def v (s : String) : Term := .var s
def atom (p : String) (args : List Term) : Atom := { pred := p, args }
def fact (p : String) (args : List String) : Fact := { pred := p, args }

/-! ## Policies and the guarantee that only proofs clear changes -/

structure Policy where
  rules : List Rule
  /-- Rule name and the theorem that justifies it. -/
  backed : List (String × String)

def Policy.backing (pol : Policy) (name : String) : Option String :=
  (pol.backed.find? (fun p => p.1 == name)).map (·.2)

/-- Every rule that concludes `p` is backed by a theorem. -/
def Policy.clearingBacked (pol : Policy) (p : String) : Bool :=
  pol.rules.all (fun r => r.head.pred != p || (pol.backing r.name).isSome)

def Policy.issues (pol : Policy) : List Issue :=
  (pol.rules.filter (fun r => r.head.pred == "proved" && (pol.backing r.name).isNone)).map
    (fun r => ({ code := "TR0206",
                 message := s!"rule \"{r.name}\" clears a change, but no theorem backs it; a policy rule may only ask for more work" } : Issue))

theorem map_some_pred {α : Type} (x : Option α) (F : α → Fact) (f : Fact)
    (h : x.map F = some f) (p : String) (hF : ∀ y, (F y).pred = p) : f.pred = p := by
  cases x with
  | none => simp at h
  | some y =>
    simp at h
    rw [← h]
    exact hF y

theorem ground_pred (s : Subst) (a : Atom) (f : Fact) (h : ground s a = some f) :
    f.pred = a.pred :=
  map_some_pred _ _ f h a.pred (fun _ => rfl)

/-- A derivable fact is given, or some rule has a head with its predicate. -/
theorem derivable_source {facts : List Fact} {rules : List Rule} {f : Fact}
    (h : Derivable facts rules f) : f ∈ facts ∨ ∃ r ∈ rules, r.head.pred = f.pred := by
  cases h with
  | given hf => exact Or.inl hf
  | byRule r s _ _ hr hg _ _ _ => exact Or.inr ⟨r, hr, (ground_pred s r.head _ hg).symm⟩

/-- If a why tree for a `p` fact passes the checker, no given fact is a `p`
fact, and every rule concluding `p` is backed, then the fact came from a
backed rule. So a policy rule can never clear a change. -/
theorem cleared_only_by_backed (pol : Policy) (facts : List Fact) (p : String) (w : Why)
    (hcheck : w.check facts pol.rules = true)
    (hfacts : facts.all (fun g => g.pred != p) = true)
    (hpol : pol.clearingBacked p = true)
    (hpred : w.fact.pred = p) :
    ∃ r ∈ pol.rules, r.head.pred = p ∧ (pol.backing r.name).isSome = true := by
  rcases derivable_source (Why.check_sound facts pol.rules w hcheck) with hf | ⟨r, hr, hpr⟩
  · have h1 : (w.fact.pred != p) = true := List.all_eq_true.mp hfacts _ hf
    rw [hpred] at h1
    simp at h1
  · refine ⟨r, hr, hpr.trans hpred, ?_⟩
    have h2 : (r.head.pred != p || (pol.backing r.name).isSome) = true :=
      List.all_eq_true.mp hpol r hr
    rw [hpr, hpred] at h2
    simpa using h2

/-! ## Facts about a change -/

/-- The weakest evidence over a range of steps. -/
def weakest (cs : List Compat) : Compat :=
  cs.foldl (fun w c => if c.rank < w.rank then c else w) (Compat.checked "")

/-- The kind of change over a range of steps, and an extension's direction. -/
def kindOf (ks : List (Option ChangeKind)) : String × Option String :=
  if ks.any (·.isNone) then ("unclassified", none)
  else if ks.any (fun k => k == some ChangeKind.breaking) then ("breaking", none)
  else
    let dirs := ks.filterMap (fun k => match k with | some (.extend d) => some d | _ => none)
    if !dirs.isEmpty then
      let back := dirs.all (fun d => d != Direction.forward)
      let fwd := dirs.all (fun d => d != Direction.backward)
      if back && fwd then ("extend", some "both")
      else if back then ("extend", some "backward")
      else if fwd then ("extend", some "forward")
      else ("breaking", none)
    else if ks.any (fun k => k == some ChangeKind.deprecate) then ("deprecate", none)
    else ("refine", none)

/-- Facts for `id` moving to `newRev`: for each direct dependent, how it
relies on `id` and what is known about the revisions it skipped; and every
edge of the graph, for indirect impact. No fact is ever a verdict. -/
def impactFacts (g : Graph) (id : ContractId) (newRev : Nat) : List Fact :=
  let direct := (g.downstreamEdges id).filter (fun e => e.revision < newRev)
  let perEdge := direct.flatMap (fun e =>
    let steps := g.stepsBetween id e.revision newRev
    let kd := kindOf (steps.map (·.1))
    let x := e.src.value
    let y := id.value
    [fact "uses" [x, y, e.kind.name], fact "change" [x, y, kd.1],
     fact "evidence" [x, y, (weakest (steps.map (·.2))).level]] ++
    (match kd.2 with
     | some d => [fact "direction" [x, y, d]]
     | none => []))
  perEdge ++ g.edges.map (fun e => fact "relies" [e.src.value, e.dst.value])

/-! ## Rules -/

def uses (k : Term) : Atom := atom "uses" [v "X", v "D", k]
def about (p : String) (val : String) : Atom := atom p [v "X", v "D", c val]
def verdict (p : String) : Atom := atom p [v "X", v "D"]

def carryOver : String := "a checked refinement carries over"

def defaultRules : List Rule := [
  { name := carryOver, head := verdict "proved",
    body := [uses (c "depends on"), about "change" "refine", about "evidence" "checked"] },
  { name := "nothing is known about the change", head := verdict "review",
    body := [uses (v "K"), about "evidence" "structural"] },
  { name := "nobody said what kind of change it is", head := verdict "review",
    body := [uses (v "K"), about "change" "unclassified"] },
  { name := "an author's claim is not a proof", head := verdict "confirm",
    body := [uses (v "K"), about "evidence" "declared"] },
  { name := "replayed vectors are not a proof", head := verdict "confirm",
    body := [uses (v "K"), about "evidence" "tested"] },
  { name := "a new case can break uses that assumed the old cases were all",
    head := verdict "review", body := [uses (c "depends on"), about "change" "extend"] },
  { name := "old consumers may not read what the new revision produces",
    head := verdict "reprove",
    body := [uses (v "K"), about "change" "extend", about "direction" "forward"] },
  { name := "a refinement must be re-established after any change",
    head := verdict "reprove", body := [uses (c "refines"), atom "change" [v "X", v "D", v "C"]] },
  { name := "a breaking change", head := verdict "reprove",
    body := [uses (v "K"), about "change" "breaking"] },
  { name := "a check failed", head := verdict "reprove",
    body := [uses (v "K"), about "evidence" "refuted"] },
  { name := "the revision is deprecated", head := verdict "deprecated",
    body := [uses (v "K"), about "change" "deprecate"] },
  { name := "needs review", head := atom "flagged" [v "X"], body := [verdict "review"] },
  { name := "needs a claim confirmed", head := atom "flagged" [v "X"], body := [verdict "confirm"] },
  { name := "needs re-proving", head := atom "flagged" [v "X"], body := [verdict "reprove"] },
  { name := "relies on something being reviewed", head := atom "waits" [v "Y", v "X"],
    body := [atom "relies" [v "Y", v "X"], atom "flagged" [v "X"]] },
  { name := "relies on something that waits", head := atom "waits" [v "Z", v "X"],
    body := [atom "relies" [v "Z", v "Y"], atom "waits" [v "Y", v "X"]] } ]

def defaultPolicy : Policy :=
  { rules := defaultRules, backed := [(carryOver, "Tribrach.Model.carry_over")] }

def templates : Templates := [
  ("uses", "$1 $3 $2"),
  ("change", "the revisions of $2 that $1 skipped are of kind $3"),
  ("evidence", "the evidence for that change is $3"),
  ("direction", "the extension is compatible $3"),
  ("relies", "$1 relies on $2"),
  ("proved", "$1 keeps every guarantee it used from $2"),
  ("review", "$1 needs review against $2"),
  ("confirm", "$1 should confirm the claim about $2"),
  ("reprove", "$1 must be re-proved against $2"),
  ("deprecated", "$1 relies on a deprecated revision of $2"),
  ("flagged", "$1 has open work"),
  ("waits", "$1 waits on $2") ]

/-! ## The report -/

structure Finding where
  contract : ContractId
  upstream : ContractId
  verdict : String
  /-- `proved` when a theorem-backed rule cleared it, otherwise `derived`. -/
  basis : String
  why : Why
  verified : Bool

structure Waiting where
  contract : ContractId
  waitsOn : ContractId
  why : Why
  verified : Bool

structure Report where
  findings : List Finding
  waiting : List Waiting
  issues : List Issue
  complete : Bool

/-- Most cautious first. -/
def verdictOrder : List String := ["reprove", "review", "confirm", "deprecated", "proved"]

/-- One verdict per dependent: a proved verdict wins, otherwise the most
cautious one. -/
def Report.decided (r : Report) : List (ContractId × String × String) :=
  let pairs := (r.findings.map (fun f => (f.contract, f.upstream))).eraseDups
  pairs.filterMap (fun p =>
    let fs := r.findings.filter (fun f => f.contract == p.1 && f.upstream == p.2)
    match fs.find? (fun f => f.basis == "proved") with
    | some f => some (p.1, f.verdict, f.basis)
    | none => fs.head?.map (fun f => (p.1, f.verdict, f.basis)))

def reason (g : Graph) (pol : Policy) (id : ContractId) (newRev : Nat) : Report :=
  let facts := impactFacts g id newRev
  let res := saturate facts pol.rules
  let cleared := facts.all (fun f => f.pred != "proved") && pol.clearingBacked "proved"
  let findings : List Finding := verdictOrder.flatMap (fun p =>
    (query res (verdict p)).filterMap (fun q =>
      match Subst.lookup q.1 "X", Subst.lookup q.1 "D" with
      | some x, some d =>
        some ({ contract := ⟨x⟩, upstream := ⟨d⟩, verdict := p,
                basis := if p == "proved" && cleared then "proved" else "derived",
                why := q.2, verified := q.2.check facts pol.rules } : Finding)
      | _, _ => none))
  let waiting : List Waiting := (query res (atom "waits" [v "Y", v "X"])).filterMap (fun q =>
    match Subst.lookup q.1 "Y", Subst.lookup q.1 "X" with
    | some y, some x =>
      some ({ contract := ⟨y⟩, waitsOn := ⟨x⟩, why := q.2,
              verified := q.2.check facts pol.rules } : Waiting)
    | _, _ => none)
  let disagree : List Issue := findings.filterMap (fun f =>
    if f.basis != "proved" then none
    else
      let others := findings.filter (fun o =>
        o.contract == f.contract && o.upstream == f.upstream && o.verdict != "proved")
      if others.isEmpty then none
      else some { code := "TR0207",
                  message := s!"{f.contract}: proved against {f.upstream}, but policy also says {", ".intercalate (others.map (·.verdict))}; the proof decides" })
  { findings, waiting, issues := pol.issues ++ disagree, complete := res.complete }

end Impact
end Tribrach
