/-!
# Logic layer: Datalog with "why" trees

A small Datalog engine. A program is a list of facts (`personal email`) and
rules (`reaches X Z :- flows X Y, reaches Y Z`). The engine derives every fact
that follows, and records for each one a *why tree*: the rule used and the
facts it was built from.

Datalog always finishes on a finite program, and once it reaches a fixpoint
its answers are complete. So "no" means "does not follow from these facts
and rules", not just "not found".

Trust model: the engine is the *suggester*. `Why.check` is a separate, much
smaller checker that re-verifies a why tree against the program without
using the engine, and `Why.check_sound` proves that anything it accepts
really follows (`Derivable`). Every answer Tribrach reports must pass it.

Rules may say "unless": a negated atom over a given predicate, such as
`not redacted D E`.
Larger external engines (Soufflé, SWI-Prolog, SAT/SMT solvers) can later
produce why trees that this same checker accepts.
-/

namespace Tribrach
namespace Logic

/-- A rule argument: a variable such as `X`, or a constant such as `email`. -/
inductive Term where
  | var (name : String)
  | const (value : String)
  deriving DecidableEq, Repr, Inhabited

/-- A pattern such as `flows X Y`. -/
structure Atom where
  pred : String
  args : List Term
  deriving DecidableEq, Repr, Inhabited

/-- A ground fact such as `flows email account`. -/
structure Fact where
  pred : String
  args : List String
  deriving DecidableEq, Repr, Inhabited

/-- `head :- body₁, …, bodyₙ, not neg₁, …, not negₘ`. Every variable must
appear in the positive body (checked by `Rule.safe`). A negated atom may only
use a *given* predicate, one that no rule derives: "unless it is listed as
redacted". That keeps "not" meaning "not among the given facts". -/
structure Rule where
  name : String
  head : Atom
  body : List Atom
  neg : List Atom := []
  deriving Repr, Inhabited

/-- Variable bindings, such as `X ↦ email`. -/
abbrev Subst := List (String × String)

/-- Why a fact holds: it was given, or a rule built it from other facts. -/
inductive Why where
  | given (f : Fact)
  | byRule (f : Fact) (rule : String) (subst : Subst) (premises : List Why)
  deriving Inhabited

def Why.fact : Why → Fact
  | .given f => f
  | .byRule f _ _ _ => f

/-! ## Matching -/

def Subst.lookup (s : Subst) (x : String) : Option String :=
  (s.find? (fun p => p.1 == x)).map (·.2)

def matchTerm (s : Subst) : Term → String → Option Subst
  | .const c, v => if c == v then some s else none
  | .var x, v =>
    match s.lookup x with
    | some w => if w == v then some s else none
    | none => some ((x, v) :: s)

def matchArgs (s : Subst) : List Term → List String → Option Subst
  | [], [] => some s
  | t :: ts, v :: vs => (matchTerm s t v).bind (fun s' => matchArgs s' ts vs)
  | _, _ => none

def matchAtom (s : Subst) (a : Atom) (f : Fact) : Option Subst :=
  if a.pred == f.pred then matchArgs s a.args f.args else none

/-- Fill in an atom's variables; fails if one is unbound. -/
def ground (s : Subst) (a : Atom) : Option Fact :=
  (a.args.mapM (fun (t : Term) =>
    match t with
    | Term.const c => some c
    | Term.var x => s.lookup x)).map (fun args => ({ pred := a.pred, args } : Fact))

def Term.vars : Term → List String
  | .var x => [x]
  | .const _ => []

/-- Every variable in the head and in negated atoms appears in the positive
body, so everything the rule mentions is ground. -/
def Rule.safe (r : Rule) : Bool :=
  ((r.head :: r.neg).flatMap (fun a => a.args.flatMap Term.vars)).all (fun x =>
    r.body.any (fun a => (a.args.flatMap Term.vars).contains x))

/-! ## Meaning

`Derivable facts rules f` says what it means for `f` to follow, independently
of any engine or checker: `f` is given, or some rule, with some variable
bindings, has a head that becomes `f`, every positive body atom becomes a
derivable fact, and every negated atom becomes a fact that isn't given. -/

/-- Fill in every atom; fails if any variable is unbound. -/
def groundAll (s : Subst) : List Atom → Option (List Fact)
  | [] => some []
  | a :: as => (ground s a).bind (fun f => (groundAll s as).map (fun fs => f :: fs))

inductive Derivable (facts : List Fact) (rules : List Rule) : Fact → Prop
  | given {f : Fact} : f ∈ facts → Derivable facts rules f
  | byRule (r : Rule) (s : Subst) (f : Fact) :
      r ∈ rules →
      ground s r.head = some f →
      (∀ a ∈ r.body, ∃ g, ground s a = some g ∧ Derivable facts rules g) →
      (∀ a ∈ r.neg, ∃ g, ground s a = some g ∧ g ∉ facts) →
      Derivable facts rules f

/-! ## The checker (trusted)

A why tree is flattened into steps, each using only facts proved by earlier
steps. The checker is small on purpose: it looks up one rule per step, fills
in its variables with the recorded bindings and compares. `Cert.check_sound`
proves that whatever it accepts is `Derivable`. -/

/-- One line of a flattened why tree. `rule = none` means a given fact. -/
structure Step where
  fact : Fact
  rule : Option String
  subst : Subst
  deriving Inhabited

def ruleNamed (rules : List Rule) (name : String) : Option Rule :=
  rules.find? (fun r => r.name == name)

/-- Every premise was proved by an earlier step. -/
def premisesOk (proven : List Fact) : Option (List Fact) → Bool
  | none => false
  | some prem => prem.all (fun g => decide (g ∈ proven))

/-- A negated atom fills in to a fact that is not given. -/
def groundNot (facts : List Fact) (s : Subst) (a : Atom) : Bool :=
  match ground s a with
  | some g => decide (g ∉ facts)
  | none => false

/-- A negated atom uses a predicate no rule derives. Not needed for
soundness, but without it "not" would depend on evaluation order. -/
def givenOnly (rules : List Rule) (a : Atom) : Bool :=
  rules.all (fun r => r.head.pred != a.pred)

def ruleStepOk (facts : List Fact) (rules : List Rule) (proven : List Fact)
    (r : Rule) (s : Subst) (f : Fact) : Bool :=
  decide (ground s r.head = some f) && premisesOk proven (groundAll s r.body) &&
    r.neg.all (fun a => groundNot facts s a && givenOnly rules a)

def stepOk (facts : List Fact) (rules : List Rule) (proven : List Fact) :
    Option String → Subst → Fact → Bool
  | none, _, f => decide (f ∈ facts)
  | some name, s, f =>
    match ruleNamed rules name with
    | some r => ruleStepOk facts rules proven r s f
    | none => false

def checkSteps (facts : List Fact) (rules : List Rule) : List Fact → List Step → Bool
  | _, [] => true
  | proven, st :: rest =>
    stepOk facts rules proven st.rule st.subst st.fact &&
      checkSteps facts rules (st.fact :: proven) rest

/-- Accept a list of steps as a proof of `goal`. -/
def Cert.check (facts : List Fact) (rules : List Rule) (steps : List Step) (goal : Fact) : Bool :=
  checkSteps facts rules [] steps && decide (goal ∈ steps.map Step.fact)

theorem groundAll_mem (s : Subst) : ∀ (body : List Atom) (fs : List Fact),
    groundAll s body = some fs → ∀ a, a ∈ body → ∃ g, g ∈ fs ∧ ground s a = some g
  | [], _, _, _, ha => by simp at ha
  | b :: bs, fs, h, a, ha => by
    cases hb : ground s b with
    | none => simp [groundAll, hb] at h
    | some g =>
      cases hbs : groundAll s bs with
      | none => simp [groundAll, hb, hbs] at h
      | some gs =>
        simp [groundAll, hb, hbs] at h
        subst h
        rcases List.mem_cons.mp ha with rfl | ha'
        · exact ⟨g, by simp, hb⟩
        · obtain ⟨g', hg', hground⟩ := groundAll_mem s bs gs hbs a ha'
          exact ⟨g', by simp [hg'], hground⟩

theorem groundNot_sound {facts : List Fact} {s : Subst} {a : Atom}
    (h : groundNot facts s a = true) : ∃ g, ground s a = some g ∧ g ∉ facts := by
  unfold groundNot at h
  cases hg : ground s a with
  | none => rw [hg] at h; simp at h
  | some g => rw [hg] at h; simp only [decide_eq_true_eq] at h; exact ⟨g, rfl, h⟩

theorem stepOk_sound (facts : List Fact) (rules : List Rule) (proven : List Fact)
    (hp : ∀ g ∈ proven, Derivable facts rules g) :
    ∀ (rule : Option String) (s : Subst) (f : Fact),
      stepOk facts rules proven rule s f = true → Derivable facts rules f
  | none, _, f, h => by
    simp only [stepOk, decide_eq_true_eq] at h
    exact Derivable.given h
  | some name, s, f, h => by
    simp only [stepOk] at h
    cases hr : ruleNamed rules name with
    | none => rw [hr] at h; simp at h
    | some r =>
      rw [hr] at h
      simp only [ruleStepOk, Bool.and_eq_true, decide_eq_true_eq] at h
      obtain ⟨⟨hhead, hprem⟩, hneg⟩ := h
      cases hga : groundAll s r.body with
      | none => rw [hga] at hprem; simp [premisesOk] at hprem
      | some prem =>
        rw [hga] at hprem
        simp only [premisesOk, List.all_eq_true, decide_eq_true_eq] at hprem
        apply Derivable.byRule r s f (List.mem_of_find?_eq_some hr) hhead
        · intro a ha
          obtain ⟨g, hg, hground⟩ := groundAll_mem s r.body prem hga a ha
          exact ⟨g, hground, hp g (hprem g hg)⟩
        · intro a ha
          have hna := (List.all_eq_true.mp hneg) a ha
          simp only [Bool.and_eq_true] at hna
          exact groundNot_sound hna.1

theorem checkSteps_sound (facts : List Fact) (rules : List Rule) :
    ∀ (proven : List Fact) (steps : List Step),
      (∀ g ∈ proven, Derivable facts rules g) →
      checkSteps facts rules proven steps = true →
      ∀ g ∈ steps.map Step.fact, Derivable facts rules g
  | _, [], _, _, g, hg => by simp at hg
  | proven, st :: rest, hp, h, g, hg => by
    simp only [checkSteps, Bool.and_eq_true] at h
    obtain ⟨hst, hrest⟩ := h
    have hf : Derivable facts rules st.fact :=
      stepOk_sound facts rules proven hp st.rule st.subst st.fact hst
    have hp' : ∀ g ∈ st.fact :: proven, Derivable facts rules g := by
      intro g' hg'
      rcases List.mem_cons.mp hg' with rfl | hg''
      · exact hf
      · exact hp g' hg''
    simp only [List.map_cons] at hg
    rcases List.mem_cons.mp hg with rfl | hg'
    · exact hf
    · exact checkSteps_sound facts rules (st.fact :: proven) rest hp' hrest g hg'

/-- **Soundness.** Whatever the checker accepts follows from the facts and rules. -/
theorem Cert.check_sound (facts : List Fact) (rules : List Rule) (steps : List Step)
    (goal : Fact) (h : Cert.check facts rules steps goal = true) :
    Derivable facts rules goal := by
  simp only [Cert.check, Bool.and_eq_true, decide_eq_true_eq] at h
  exact checkSteps_sound facts rules [] steps (by simp) h.1 goal h.2

mutual
/-- Flatten a why tree into steps, premises first. -/
def Why.steps : Why → List Step
  | .given f => [{ fact := f, rule := none, subst := [] }]
  | .byRule f name s ps => Why.stepsAll ps ++ [{ fact := f, rule := some name, subst := s }]

def Why.stepsAll : List Why → List Step
  | [] => []
  | w :: ws => Why.steps w ++ Why.stepsAll ws
end

/-- Re-verify a why tree against the program, without the engine. -/
def Why.check (facts : List Fact) (rules : List Rule) (w : Why) : Bool :=
  Cert.check facts rules w.steps w.fact

theorem Why.check_sound (facts : List Fact) (rules : List Rule) (w : Why)
    (h : w.check facts rules = true) : Derivable facts rules w.fact :=
  Cert.check_sound facts rules w.steps w.fact h

/-! ## The engine (untrusted)

Bottom-up evaluation in rounds. A fact gets the why tree from the first round
that derives it, so trees are as shallow as the rules allow. -/

abbrev Db := List (Fact × Why)

/-- All ways to satisfy a rule body from known facts. -/
def solve (known : Db) : List Atom → Subst → List (Subst × List Why)
  | [], s => [(s, [])]
  | a :: rest, s =>
    known.flatMap (fun p =>
      match matchAtom s a p.1 with
      | some s' => (solve known rest s').map (fun q => (q.1, p.2 :: q.2))
      | none => [])

def addNew (db : Db) (f : Fact) (w : Why) : Db :=
  if db.any (fun p => p.1 == f) then db else db ++ [(f, w)]

/-- One round: apply every rule to the facts known at the start of the round. -/
def round (facts : List Fact) (rules : List Rule) (known : Db) : Db :=
  rules.foldl (fun acc r =>
    (solve known r.body []).foldl (fun acc2 q =>
      if r.neg.all (fun a => groundNot facts q.1 a) then
        match ground q.1 r.head with
        | some f => addNew acc2 f (.byRule f r.name q.1 q.2)
        | none => acc2
      else acc2) acc) known

/-- The result of running a program. -/
structure Result where
  db : Db
  /-- True if no new facts appeared before fuel ran out, so answers are complete. -/
  complete : Bool

def saturateFrom (facts : List Fact) (rules : List Rule) : Nat → Db → Result
  | 0, db => { db, complete := false }
  | n + 1, db =>
    let next := round facts rules db
    if next.length == db.length then { db, complete := true }
    else saturateFrom facts rules n next

/-- Derive everything. `fuel` bounds the number of rounds. -/
def saturate (facts : List Fact) (rules : List Rule) (fuel : Nat := 1000) : Result :=
  saturateFrom facts rules fuel (facts.foldl (fun db f => addNew db f (.given f)) [])

/-- Facts matching a pattern, with the variable bindings and why tree. -/
def query (res : Result) (q : Atom) : List (Subst × Why) :=
  res.db.filterMap (fun p => (matchAtom [] q p.1).map (fun s => (s, p.2)))

/-! ## Plain English -/

/-- Sentence templates per predicate, with `$1`, `$2`, … for arguments, such
as `("flows", "$1 is sent to $2")`. -/
abbrev Templates := List (String × String)

def say (tpl : Templates) (f : Fact) : String :=
  match tpl.find? (fun p => p.1 == f.pred) with
  | some p =>
    ((List.range f.args.length).zip f.args).foldl
      (fun acc q => acc.replace s!"${q.1 + 1}" q.2) p.2
  | none => f.pred ++ " " ++ " ".intercalate f.args

/-- What a rule's negated atoms say under some bindings, as plain English. -/
def negLines (tpl : Templates) (rules : List Rule) (name : String) (s : Subst) : List String :=
  match ruleNamed rules name with
  | some r => r.neg.filterMap (fun a => (ground s a).map (fun g => s!"nothing says {say tpl g}"))
  | none => []

/-- A why tree as a nested Markdown list. -/
partial def Why.explain (tpl : Templates) (rules : List Rule) (indent : String := "") :
    Why → List String
  | .given f => [s!"{indent}- {say tpl f} (given)"]
  | .byRule f rule s ps =>
    [s!"{indent}- {say tpl f}, by rule \"{rule}\", because:"] ++
      ps.flatMap (Why.explain tpl rules (indent ++ "  ")) ++
      (negLines tpl rules rule s).map (fun l => s!"{indent}  - {l}")

end Logic
end Tribrach
